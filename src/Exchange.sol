// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {Martingaler} from "./Martingaler.sol";
import {Position, PositionLib} from "./PositionLib.sol";
import {InstrumentLib} from "./InstrumentLib.sol";
import {IExchange} from "./interfaces/IExchange.sol";

contract Exchange is IExchange, Ownable2Step, Martingaler {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PositionLib for Position;
    using InstrumentLib for InstrumentLib.Instrument;

    struct PriceCache {
        uint256[] prices;
        bool[] loaded;
    }

    struct CloseTotals {
        uint256 marginReturned;
        uint256 losses;
        uint256 wins;
        uint256 fees;
    }

    uint256 public constant PRECISION = 1e18;

    IPyth public immutable pyth;
    IERC20 public immutable collateralToken;
    uint256 public immutable collateralScale;

    uint256 public maxPriceAge = 60;
    mapping(uint32 => InstrumentLib.Instrument) public instruments;
    uint32 public instrumentCount;
    mapping(address => uint256) public balances;
    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;
    mapping(address => uint256[]) internal userOpenPositionIds;
    mapping(uint256 => uint256) public positionIndex;
    uint256 public totalBalances;
    uint256 public totalLockedMargin;
    uint256 public lossFeeRate = 0.02e18;
    uint256 public winFeeRate = 0.02e18;
    uint256 public liquidationFeeRate = 0.02e18;
    uint256 public protocolFeeAccumulator;
    uint256 public minCollateral = 1e18;
    uint256 public minNotional;
    bool public tradingPaused;

    constructor(
        address owner_,
        address pyth_,
        address collateral_
    ) Ownable(owner_) {
        pyth = IPyth(pyth_);
        collateralToken = IERC20(collateral_);
        uint8 decimals = IERC20Metadata(collateral_).decimals();
        if (decimals > 18) revert UnsupportedCollateralDecimals();
        collateralScale = 10 ** uint256(18 - decimals);
    }

    function openPosition(
        uint32 instrumentId,
        bool isLong,
        uint128 collateral,
        uint32 leverage,
        bytes[] calldata priceUpdate
    ) external payable returns (uint256 positionId) {
        uint256 fromWallet;
        (positionId, fromWallet) = _openPosition(
            msg.sender,
            instrumentId,
            isLong,
            collateral,
            leverage,
            priceUpdate
        );
        if (fromWallet != 0) {
            collateralToken.safeTransferFrom(
                msg.sender,
                address(this),
                fromWallet
            );
        }
    }

    function closePositions(
        uint256[] calldata positionIds,
        bytes[] calldata priceUpdate
    ) external payable {
        _closePositions(msg.sender, positionIds, priceUpdate);
    }

    function claim(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 debit = amount * collateralScale;
        if (balances[msg.sender] < debit) revert InsufficientBalance();
        balances[msg.sender] -= debit;
        totalBalances -= debit;
        collateralToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, debit);
    }

    function liquidate(
        uint256 positionId,
        bytes[] calldata priceUpdate
    ) external payable {
        _requireTradingActive();
        _updatePyth(priceUpdate);
        Position memory p = positions[positionId];
        if (!p.isOpen) revert PositionNotOpen();
        (
            bool liquidatable,
            uint256 price,
            uint256 liqPrice
        ) = _checkLiquidatable(p, _newPriceCache(0));
        if (!liquidatable) revert NotLiquidatable();
        _executeLiquidation(positionId, p, price, liqPrice);
    }

    function liquidateBatch(
        uint256[] calldata positionIds,
        bytes[] calldata priceUpdate
    ) external payable returns (uint256 liquidated) {
        _requireTradingActive();
        _updatePyth(priceUpdate);
        PriceCache memory cache = _newPriceCache(instrumentCount);
        for (uint256 i; i < positionIds.length; ++i) {
            if (_tryLiquidate(cache, positionIds[i])) ++liquidated;
        }
        emit LiquidationBatchProcessed(positionIds.length, liquidated);
    }

    function fundHouse(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        _settleLoss(amount * collateralScale);
        emit HouseFunded(msg.sender, amount * collateralScale);
    }

    function positionOwner(uint256 positionId) external view returns (address) {
        return positions[positionId].owner;
    }

    function getUserOpenPositionIds(
        address user
    ) external view returns (uint256[] memory) {
        return userOpenPositionIds[user];
    }

    function getMarketOi(
        uint32 instrumentId
    )
        external
        view
        returns (
            uint256 longSize,
            uint256 shortSize,
            uint256 longCap,
            uint256 shortCap,
            uint256 sizeScale
        )
    {
        InstrumentLib.Oi storage oi = instruments[instrumentId].oi;
        return (
            oi.longSize,
            oi.shortSize,
            oi.longCap,
            oi.shortCap,
            oi.sizeScale
        );
    }

    function liquidationPrice(
        uint256 positionId
    ) external view returns (uint256) {
        Position memory p = positions[positionId];
        return
            p.liquidationPrice(
                instruments[p.instrumentId].config.liquidationBuffer
            );
    }

    function previewPnl(
        uint256 positionId,
        uint256 markPrice
    ) external view returns (int256 rawPnl, int256 pnl) {
        Position memory p = positions[positionId];
        return p.pnl(markPrice, instruments[p.instrumentId].config);
    }

    function currentPrice(uint32 instrumentId) external view returns (uint256) {
        InstrumentLib.Instrument storage inst = instruments[instrumentId];
        inst.requireExists();
        return inst.price(pyth, maxPriceAge);
    }

    function pythUpdateFee(
        bytes[] calldata priceUpdate
    ) external view returns (uint256) {
        return priceUpdate.length == 0 ? 0 : pyth.getUpdateFee(priceUpdate);
    }

    function setMaxPriceAge(uint256 maxPriceAge_) external onlyOwner {
        maxPriceAge = maxPriceAge_;
        emit MaxPriceAgeUpdated(maxPriceAge_);
    }

    function setTradingPaused(bool paused) external onlyOwner {
        tradingPaused = paused;
        emit TradingPausedUpdated(paused);
    }

    function setFeeRates(
        uint256 lossFeeRate_,
        uint256 winFeeRate_,
        uint256 liquidationFeeRate_
    ) external onlyOwner {
        lossFeeRate = lossFeeRate_;
        winFeeRate = winFeeRate_;
        liquidationFeeRate = liquidationFeeRate_;
        emit FeeRatesUpdated(lossFeeRate_, winFeeRate_, liquidationFeeRate_);
    }

    function setTradeMinimums(uint256 minCollateral_, uint256 minNotional_) external onlyOwner {
        minCollateral = minCollateral_;
        minNotional = minNotional_;
        emit TradeMinimumsUpdated(minCollateral_, minNotional_);
    }

    function addInstrument(
        InstrumentLib.Config calldata config,
        uint64 sizeScale,
        string calldata symbol
    ) external onlyOwner returns (uint32 instrumentId) {
        instrumentId = instrumentCount++;
        instruments[instrumentId].init(config, sizeScale);
        emit InstrumentAdded(instrumentId, config.priceId, symbol);
    }

    function setRiskParams(
        uint32 instrumentId,
        uint256 maxLeverage,
        uint256 maxNotional
    ) external onlyOwner {
        instruments[instrumentId].setRiskParams(maxLeverage, maxNotional);
        emit InstrumentRiskUpdated(instrumentId, maxLeverage, maxNotional);
    }

    function setImpactConfig(
        uint32 instrumentId,
        uint256 impactC,
        uint256 impactB,
        uint256 impactA,
        uint256 profitHaircut
    ) external onlyOwner {
        instruments[instrumentId].setImpactConfig(
            impactC,
            impactB,
            impactA,
            profitHaircut
        );
        emit InstrumentImpactConfigUpdated(
            instrumentId,
            impactC,
            impactB,
            impactA,
            profitHaircut
        );
    }

    function setOiCaps(
        uint32 instrumentId,
        uint96 longCap,
        uint96 shortCap
    ) external onlyOwner {
        instruments[instrumentId].setOiCaps(longCap, shortCap);
        emit MarketOiCapsUpdated(instrumentId, longCap, shortCap);
    }

    receive() external payable {}

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function claimProtocolFees() external onlyOwner {
        uint256 amount = protocolFeeAccumulator;
        if (amount == 0) return;
        protocolFeeAccumulator = 0;
        (uint256 paid, ) = _settleWin(msg.sender, amount);
        emit ProtocolFeesClaimed(msg.sender, amount, paid);
    }

    function _credit(address user, uint256 amount) internal override {
        balances[user] += amount;
        totalBalances += amount;
    }

    function _requireTradingActive() internal view {
        if (tradingPaused) revert TradingPaused();
    }

    function _updatePyth(bytes[] calldata priceUpdate) internal {
        if (priceUpdate.length == 0) return;
        uint256 fee = pyth.getUpdateFee(priceUpdate);
        if (address(this).balance < fee) revert InsufficientUpdateFee();
        pyth.updatePriceFeeds{value: fee}(priceUpdate);
    }

    function _openPosition(
        address trader,
        uint32 instrumentId,
        bool isLong,
        uint128 collateral,
        uint32 leverage,
        bytes[] calldata priceUpdate
    ) internal returns (uint256 positionId, uint256 fromWallet) {
        _requireTradingActive();
        _updatePyth(priceUpdate);
        InstrumentLib.Instrument storage inst = instruments[instrumentId];
        inst.checkOpen(collateral, leverage, minCollateral, minNotional);
        uint256 price = inst.price(pyth, maxPriceAge);
        fromWallet = _lockMargin(trader, collateral);

        Position memory p = Position({
            owner: trader,
            instrumentId: instrumentId,
            entryPrice: price.toUint64(),
            collateral: collateral,
            leverage: leverage,
            openedAt: uint64(block.timestamp),
            isLong: isLong,
            isOpen: true
        });
        inst.increaseOi(isLong, p.size(inst.oi.sizeScale));
        positionId = nextPositionId++;
        positions[positionId] = p;
        uint256[] storage ids = userOpenPositionIds[trader];
        ids.push(positionId);
        positionIndex[positionId] = ids.length;
        emit PositionOpened(
            positionId,
            trader,
            instrumentId,
            isLong,
            p.entryPrice,
            collateral,
            leverage
        );
    }

    function _lockMargin(
        address trader,
        uint256 collateral
    ) internal returns (uint256 fromWallet) {
        uint256 balance = balances[trader];
        uint256 fromBalance = balance < collateral ? balance : collateral;
        fromBalance -= fromBalance % collateralScale;
        if (fromBalance != 0) {
            balances[trader] = balance - fromBalance;
            totalBalances -= fromBalance;
        }
        uint256 remaining = collateral - fromBalance;
        if (remaining != 0) {
            fromWallet = remaining / collateralScale;
            if (fromWallet * collateralScale != remaining) {
                revert CollateralPrecision();
            }
        }
        totalLockedMargin += collateral;
    }

    function _closePositions(
        address trader,
        uint256[] calldata positionIds,
        bytes[] calldata priceUpdate
    ) internal {
        _requireTradingActive();
        _updatePyth(priceUpdate);
        uint256 count = positionIds.length;
        if (count == 0) revert EmptyCloseList();

        PriceCache memory cache = _newPriceCache(instrumentCount);
        CloseTotals memory totals;
        bool closedAny;
        for (uint256 i; i < count; ++i) {
            uint256 positionId = positionIds[i];
            Position memory p = positions[positionId];
            if (!p.isOpen || p.owner != trader) continue;
            closedAny = true;
            _closePosition(trader, positionId, p, cache, totals);
        }
        if (!closedAny) return;

        uint256 balanceBefore = balances[trader];
        if (totals.marginReturned != 0) _credit(trader, totals.marginReturned);
        if (totals.losses != 0) _settleLoss(totals.losses);
        if (totals.wins != 0) _settleWin(trader, totals.wins);
        if (totals.fees != 0) protocolFeeAccumulator += totals.fees;
        uint256 newBalance = balances[trader];
        emit PositionsClosed(
            trader,
            newBalance - balanceBefore,
            newBalance,
            totals.fees
        );
    }

    function _closePosition(
        address trader,
        uint256 positionId,
        Position memory p,
        PriceCache memory cache,
        CloseTotals memory totals
    ) internal {
        InstrumentLib.Instrument storage inst = instruments[p.instrumentId];
        uint256 price = _cachedPrice(cache, p.instrumentId, inst);
        positions[positionId].isOpen = false;
        totalLockedMargin -= p.collateral;
        inst.decreaseOi(p.isLong, p.size(inst.oi.sizeScale));
        (int256 rawPnl, int256 pnl) = p.pnl(price, inst.config);
        _removeUserPosition(trader, positionId);
        uint256 fee = _accumulateClose(totals, p.collateral, pnl);
        emit PositionClosed(positionId, trader, price, rawPnl, pnl, fee);
    }

    function _accumulateClose(
        CloseTotals memory totals,
        uint256 collateral,
        int256 pnl
    ) internal view returns (uint256 fee) {
        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            fee = (profit * winFeeRate) / PRECISION;
            totals.marginReturned += collateral;
            totals.wins += profit - fee;
        } else {
            uint256 loss = uint256(-pnl);
            fee = (loss * lossFeeRate) / PRECISION;
            totals.marginReturned += collateral - loss;
            totals.losses += loss;
        }
        totals.fees += fee;
    }

    function _tryLiquidate(
        PriceCache memory cache,
        uint256 positionId
    ) internal returns (bool) {
        Position memory p = positions[positionId];
        if (!p.isOpen) return false;
        (
            bool liquidatable,
            uint256 price,
            uint256 liqPrice
        ) = _checkLiquidatable(p, cache);
        if (!liquidatable) return false;
        _executeLiquidation(positionId, p, price, liqPrice);
        return true;
    }

    function _checkLiquidatable(
        Position memory p,
        PriceCache memory cache
    )
        internal
        view
        returns (bool liquidatable, uint256 price, uint256 liqPrice)
    {
        InstrumentLib.Instrument storage inst = instruments[p.instrumentId];
        price = _cachedPrice(cache, p.instrumentId, inst);
        (liquidatable, liqPrice) = p.isLiquidatable(
            price,
            inst.config.liquidationBuffer
        );
    }

    function _executeLiquidation(
        uint256 positionId,
        Position memory p,
        uint256 price,
        uint256 liqPrice
    ) internal {
        positions[positionId].isOpen = false;
        address trader = p.owner;
        _removeUserPosition(trader, positionId);
        uint256 collateral = p.collateral;
        InstrumentLib.Instrument storage inst = instruments[p.instrumentId];
        inst.decreaseOi(p.isLong, p.size(inst.oi.sizeScale));
        totalLockedMargin -= collateral;
        _settleLoss(collateral);
        uint256 fee = (collateral * liquidationFeeRate) / PRECISION;
        if (fee != 0) protocolFeeAccumulator += fee;
        emit Liquidated(positionId, trader, price, liqPrice, fee);
    }

    function _newPriceCache(
        uint256 length
    ) internal pure returns (PriceCache memory) {
        return PriceCache(new uint256[](length), new bool[](length));
    }

    function _cachedPrice(
        PriceCache memory cache,
        uint32 instrumentId,
        InstrumentLib.Instrument storage inst
    ) internal view returns (uint256) {
        if (
            instrumentId >= cache.loaded.length ||
            instrumentId >= cache.prices.length
        ) {
            return inst.price(pyth, maxPriceAge);
        }
        if (!cache.loaded[instrumentId]) {
            cache.prices[instrumentId] = inst.price(pyth, maxPriceAge);
            cache.loaded[instrumentId] = true;
        }
        return cache.prices[instrumentId];
    }

    function _removeUserPosition(address user, uint256 positionId) internal {
        uint256 index = positionIndex[positionId];
        if (index == 0) return;
        uint256[] storage ids = userOpenPositionIds[user];
        uint256 lastIndex = ids.length - 1;
        if (index - 1 != lastIndex) {
            uint256 lastId = ids[lastIndex];
            ids[index - 1] = lastId;
            positionIndex[lastId] = index;
        }
        ids.pop();
        delete positionIndex[positionId];
    }
}
