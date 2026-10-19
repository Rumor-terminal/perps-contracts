// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {Martingaler} from "./Martingaler.sol";
import {Position, PositionLib} from "./PositionLib.sol";
import {Config, Instrument, InstrumentLib, WAD} from "./InstrumentLib.sol";
import {IExchange} from "./interfaces/IExchange.sol";

contract Exchange is IExchange, Ownable2Step, Martingaler {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.UintSet;
    using PositionLib for Position;
    using InstrumentLib for Instrument;

    struct CloseTotals {
        uint256 marginReturned;
        uint256 losses;
        uint256 owed;
        uint256 fees;
    }

    IPyth public immutable pyth;
    IERC20 public immutable collateralToken;
    uint256 public immutable collateralScale;

    uint256 public maxPriceAge = 60;
    mapping(uint32 => Instrument) public instruments;
    uint32 public instrumentCount;
    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;
    mapping(address => EnumerableSet.UintSet) internal userOpenPositionIds;
    uint256 public totalLockedMargin;
    uint256 public lossFeeRate = 0.02e18;
    uint256 public winFeeRate = 0.02e18;
    uint256 public liquidationFeeRate = 0.02e18;
    uint256 public protocolFeeAccumulator;
    uint256 public minCollateral = WAD;
    uint256 public minNotional;
    bool public tradingPaused;

    constructor(address owner_, address pyth_, address collateral_) Ownable(owner_) {
        pyth = IPyth(pyth_);
        collateralToken = IERC20(collateral_);

        uint8 decimals = IERC20Metadata(collateral_).decimals();
        if (decimals > 18) revert UnsupportedCollateralDecimals();
        collateralScale = 10 ** uint256(18 - decimals);
    }

    modifier whenTradingActive() {
        if (tradingPaused) revert TradingPaused();
        _;
    }

    modifier withPriceUpdate(bytes[] calldata priceUpdate) {
        if (priceUpdate.length != 0) {
            uint256 fee = pyth.getUpdateFee(priceUpdate);
            if (address(this).balance < fee) revert InsufficientUpdateFee();
            pyth.updatePriceFeeds{value: fee}(priceUpdate);
        }
        _;
    }

    function openPosition(
        uint32 instrumentId,
        bool isLong,
        uint128 collateral,
        uint32 leverage,
        bytes[] calldata priceUpdate
    ) external payable whenTradingActive withPriceUpdate(priceUpdate) returns (uint256 positionId) {
        Instrument storage instrument = instruments[instrumentId];
        instrument.checkOpen(collateral, leverage, minCollateral, minNotional);
        uint256 price = instrument.price(pyth, maxPriceAge);

        if (collateral % collateralScale != 0) revert CollateralPrecision();
        (uint256 debited, uint256 cash) = _tryDebit(msg.sender, collateral, collateralScale);
        totalLockedMargin += cash;

        Position memory p = Position({
            owner: msg.sender,
            instrumentId: instrumentId,
            entryPrice: price.toUint64(),
            collateral: collateral,
            debited: debited.toUint128(),
            leverage: leverage,
            openedAt: uint64(block.timestamp),
            isLong: isLong,
            isOpen: true
        });
        instrument.increaseOi(isLong, p.size(instrument.oi.sizeScale));

        positionId = nextPositionId++;
        positions[positionId] = p;
        userOpenPositionIds[msg.sender].add(positionId);

        emit PositionOpened(positionId, msg.sender, instrumentId, isLong, p.entryPrice, collateral, leverage);
        if (cash != 0) collateralToken.safeTransferFrom(msg.sender, address(this), cash / collateralScale);
    }

    function closePositions(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        whenTradingActive
        withPriceUpdate(priceUpdate)
    {
        uint256[] memory prices = new uint256[](instrumentCount);
        CloseTotals memory totals;
        bool closedAny;
        for (uint256 i; i < positionIds.length; ++i) {
            uint256 positionId = positionIds[i];
            Position memory p = positions[positionId];
            if (!p.isOpen || p.owner != msg.sender) continue;
            closedAny = true;
            _closePosition(positionId, p, prices, totals);
        }
        if (!closedAny) revert NothingToClose();

        if (totals.losses != 0) _settleLoss(totals.losses);
        if (totals.fees != 0) protocolFeeAccumulator += totals.fees;

        uint256 paid = totals.marginReturned;
        uint256 queued;
        if (totals.owed != 0) {
            (uint256 instant, uint256 pending) = _settleWin(msg.sender, totals.owed);
            paid += instant;
            queued = pending;
        }
        if (totals.marginReturned != 0) _pay(msg.sender, totals.marginReturned);

        emit PositionsClosed(msg.sender, paid, queued, totals.fees);
    }

    function liquidateBatch(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        whenTradingActive
        withPriceUpdate(priceUpdate)
        returns (uint256 liquidated)
    {
        uint256[] memory prices = new uint256[](instrumentCount);
        for (uint256 i; i < positionIds.length; ++i) {
            if (_tryLiquidate(prices, positionIds[i])) ++liquidated;
        }
    }

    function fundHouse(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 funded = amount * collateralScale;

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        _settleLoss(funded);

        emit HouseFunded(msg.sender, funded);
    }

    function getUserOpenPositionIds(address user) external view returns (uint256[] memory) {
        return userOpenPositionIds[user].values();
    }

    function liquidationPrice(uint256 positionId) external view returns (uint256) {
        Position memory p = positions[positionId];
        return p.liquidationPrice(instruments[p.instrumentId].config.liquidationBuffer);
    }

    function previewPnl(uint256 positionId, uint256 markPrice) external view returns (int256 rawPnl, int256 pnl) {
        Position memory p = positions[positionId];
        return p.pnl(markPrice, instruments[p.instrumentId].config);
    }

    function pythUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256) {
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

    function setFeeRates(uint256 lossFeeRate_, uint256 winFeeRate_, uint256 liquidationFeeRate_) external onlyOwner {
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

    function addInstrument(Config calldata config, uint64 sizeScale, string calldata symbol)
        external
        onlyOwner
        returns (uint32 instrumentId)
    {
        instrumentId = instrumentCount++;
        instruments[instrumentId].init(config, sizeScale);

        emit InstrumentAdded(instrumentId, config.priceId, symbol);
    }

    function setRiskParams(uint32 instrumentId, uint256 maxLeverage, uint256 maxNotional) external onlyOwner {
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
        instruments[instrumentId].setImpactConfig(impactC, impactB, impactA, profitHaircut);
        emit InstrumentImpactConfigUpdated(instrumentId, impactC, impactB, impactA, profitHaircut);
    }

    function setOiCaps(uint32 instrumentId, uint96 longCap, uint96 shortCap) external onlyOwner {
        instruments[instrumentId].setOiCaps(longCap, shortCap);
        emit MarketOiCapsUpdated(instrumentId, longCap, shortCap);
    }

    receive() external payable {}

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        Address.sendValue(payable(to), amount);
    }

    function claimProtocolFees() external onlyOwner {
        uint256 amount = protocolFeeAccumulator;
        if (amount == 0) return;
        protocolFeeAccumulator = 0;

        (uint256 paid,) = _settleWin(msg.sender, amount);
        emit ProtocolFeesClaimed(msg.sender, amount, paid);
    }

    function _pay(address user, uint256 amount) internal override {
        uint256 tokens = amount / collateralScale;
        treasury += amount - tokens * collateralScale;
        if (tokens != 0) collateralToken.safeTransfer(user, tokens);
    }

    function _closePosition(uint256 positionId, Position memory p, uint256[] memory prices, CloseTotals memory totals)
        internal
    {
        Instrument storage instrument = instruments[p.instrumentId];
        uint256 price = _cachedPrice(prices, p.instrumentId, instrument);
        _release(positionId, p);

        (int256 rawPnl, int256 pnl) = p.pnl(price, instrument.config);
        uint256 fee = _accumulateClose(totals, p.collateral, p.debited, pnl);
        emit PositionClosed(positionId, p.owner, price, rawPnl, pnl, fee);
    }

    function _accumulateClose(CloseTotals memory totals, uint256 collateral, uint256 debited, int256 pnl)
        internal
        view
        returns (uint256 fee)
    {
        uint256 cash = collateral - debited;

        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            fee = (profit * winFeeRate) / WAD;

            totals.marginReturned += cash;
            totals.owed += debited + profit - fee;
        } else {
            uint256 loss = uint256(-pnl);
            fee = (loss * lossFeeRate) / WAD;
            uint256 debitLoss = loss < debited ? loss : debited;
            uint256 cashLoss = loss - debitLoss;

            totals.marginReturned += cash - cashLoss;
            totals.losses += cashLoss;
            totals.owed += debited - debitLoss;
        }

        totals.fees += fee;
    }

    function _tryLiquidate(uint256[] memory prices, uint256 positionId) internal returns (bool) {
        Position memory p = positions[positionId];
        if (!p.isOpen) return false;

        Instrument storage instrument = instruments[p.instrumentId];
        uint256 price = _cachedPrice(prices, p.instrumentId, instrument);
        (bool liquidatable, uint256 liqPrice) = p.isLiquidatable(price, instrument.config.liquidationBuffer);
        if (!liquidatable) return false;

        uint256 cash = _release(positionId, p);
        if (cash != 0) _settleLoss(cash);
        uint256 fee = (p.collateral * liquidationFeeRate) / WAD;
        if (fee != 0) protocolFeeAccumulator += fee;
        emit Liquidated(positionId, p.owner, price, liqPrice, fee);
        return true;
    }

    function _release(uint256 positionId, Position memory p) internal returns (uint256 cash) {
        cash = p.collateral - p.debited;
        Instrument storage instrument = instruments[p.instrumentId];

        positions[positionId].isOpen = false;
        totalLockedMargin -= cash;
        instrument.decreaseOi(p.isLong, p.size(instrument.oi.sizeScale));
        userOpenPositionIds[p.owner].remove(positionId);
    }

    function _cachedPrice(uint256[] memory prices, uint32 instrumentId, Instrument storage instrument)
        internal
        view
        returns (uint256)
    {
        if (prices[instrumentId] == 0) prices[instrumentId] = instrument.price(pyth, maxPriceAge);
        return prices[instrumentId];
    }
}
