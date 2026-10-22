// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {Martingaler} from "./Martingaler.sol";
import {Position, PositionLib} from "./PositionLib.sol";
import {Config, Instrument, InstrumentLib, WAD} from "./InstrumentLib.sol";
import {TraderStats, TraderStatsLib} from "./TraderStatsLib.sol";
import {IPerpetualFutures} from "./interfaces/IPerpetualFutures.sol";

contract PerpetualFutures is IPerpetualFutures, Ownable2StepUpgradeable, UUPSUpgradeable, Martingaler {
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.UintSet;
    using PositionLib for Position;
    using InstrumentLib for Instrument;
    using TraderStatsLib for TraderStats;

    IPyth public pyth;

    uint256 public maxPriceAge;
    mapping(uint32 => Instrument) public instruments;
    uint32 public instrumentCount;
    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;
    mapping(address => EnumerableSet.UintSet) internal userOpenPositionIds;
    uint256 public totalLockedMargin;
    uint256 public lossFeeRate;
    uint256 public winFeeRate;
    uint256 public liquidationFeeRate;
    uint256 public minCollateral;
    uint256 public minNotional;
    bool public tradingPaused;
    mapping(address => TraderStats) public traderStats;
    TraderStats public totalStats;

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address pyth_, address collateral_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();

        pyth = IPyth(pyth_);
        _initCollateral(collateral_);

        maxPriceAge = 60;
        lossFeeRate = 0.02e18;
        winFeeRate = 0.02e18;
        liquidationFeeRate = 0.02e18;
        minCollateral = WAD;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

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
        instrument.validateOpenPosition(collateral, leverage);

        uint256 debited = _debit(msg.sender, collateral);
        Position memory p = Position({
            owner: msg.sender,
            instrumentId: instrumentId,
            entryPrice: instrument.price(pyth, maxPriceAge).toUint64(),
            collateral: collateral,
            debited: debited.toUint128(),
            leverage: leverage,
            openedAt: uint64(block.timestamp),
            isLong: isLong,
            isOpen: true
        });
        p.validate(minCollateral, minNotional, collateralScale);

        positionId = nextPositionId++;
        positions[positionId] = p;
        userOpenPositionIds[msg.sender].add(positionId);

        totalLockedMargin += collateral - debited;
        instrument.increaseOi(isLong, p.size());
        traderStats[msg.sender].recordOpen(p.notional());
        totalStats.recordOpen(p.notional());

        emit PositionOpened(positionId, msg.sender, instrumentId, isLong, p.entryPrice, collateral, leverage);
    }

    function closePositions(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        whenTradingActive
        withPriceUpdate(priceUpdate)
    {
        uint256[] memory prices = new uint256[](instrumentCount);
        uint256 totalLost;
        uint256 totalReturned;
        uint256 totalOwed;
        uint256 totalFees;
        for (uint256 i; i < positionIds.length; ++i) {
            uint256 positionId = positionIds[i];
            Position memory p = positions[positionId];
            if (!p.isOpen || p.owner != msg.sender) continue;
            (uint256 lost, uint256 returned, uint256 owed, uint256 fee) = _closePosition(positionId, p, prices);
            totalLost += lost;
            totalReturned += returned;
            totalOwed += owed;
            totalFees += fee;
        }

        _settleNet(msg.sender, totalReturned, totalLost, totalOwed);
        _payFee(owner(), totalFees);
    }

    function liquidateBatch(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        whenTradingActive
        withPriceUpdate(priceUpdate)
    {
        uint256[] memory prices = new uint256[](instrumentCount);
        uint256 totalFees;
        for (uint256 i; i < positionIds.length; ++i) {
            totalFees += _tryLiquidate(positionIds[i], prices);
        }
        _payFee(owner(), totalFees);
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

    function addInstrument(Config calldata config, string calldata symbol)
        external
        onlyOwner
        returns (uint32 instrumentId)
    {
        instrumentId = instrumentCount++;
        instruments[instrumentId].init(config);

        emit InstrumentAdded(instrumentId, config.priceId, symbol);
        emit InstrumentRiskUpdated(instrumentId, config.maxLeverage, config.maxNotional, config.liquidationBuffer);
        emit InstrumentHaircutConfigUpdated(
            instrumentId, config.moveScale, config.referenceSize, config.marketFactor, config.profitHaircut
        );
    }

    function setRiskParams(uint32 instrumentId, uint256 maxLeverage, uint256 maxNotional, uint256 liquidationBuffer)
        external
        onlyOwner
    {
        instruments[instrumentId].setRiskParams(maxLeverage, maxNotional, liquidationBuffer);
        emit InstrumentRiskUpdated(instrumentId, maxLeverage, maxNotional, liquidationBuffer);
    }

    function setHaircutConfig(
        uint32 instrumentId,
        uint256 moveScale,
        uint256 referenceSize,
        uint256 marketFactor,
        uint256 profitHaircut
    ) external onlyOwner {
        instruments[instrumentId].setHaircutConfig(moveScale, referenceSize, marketFactor, profitHaircut);
        emit InstrumentHaircutConfigUpdated(instrumentId, moveScale, referenceSize, marketFactor, profitHaircut);
    }

    function setOiCaps(uint32 instrumentId, uint128 longCap, uint128 shortCap) external onlyOwner {
        instruments[instrumentId].setOiCaps(longCap, shortCap);
        emit InstrumentOiCapsUpdated(instrumentId, longCap, shortCap);
    }

    receive() external payable {}

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        Address.sendValue(payable(to), amount);
    }

    function _settleNet(address trader, uint256 returned, uint256 lost, uint256 owed) internal {
        if (owed > lost) {
            _settleWin(trader, owed - lost);
        } else {
            _settleLoss(lost - owed);
        }

        uint256 direct = returned + Math.min(owed, lost);
        if (direct != 0) _pay(trader, direct);
    }

    function _closePosition(uint256 positionId, Position memory p, uint256[] memory prices)
        internal
        returns (uint256 lost, uint256 returned, uint256 owed, uint256 fee)
    {
        Instrument storage instrument = instruments[p.instrumentId];
        uint256 price = _cachedPrice(prices, p.instrumentId, instrument);
        uint256 cash = _release(positionId, p);

        (int256 rawPnl, int256 pnl) = p.pnl(price, instrument.config);
        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            fee = (profit * winFeeRate) / WAD;
            returned = cash;
            owed = p.debited + profit - fee;
        } else {
            uint256 loss = uint256(-pnl);
            fee = (loss * lossFeeRate) / WAD;
            uint256 lossFromDebit = Math.min(loss, p.debited);
            lost = loss - lossFromDebit;
            returned = cash - lost;
            owed = p.debited - lossFromDebit;
        }
        traderStats[p.owner].recordClose(pnl, fee);
        totalStats.recordClose(pnl, fee);
        emit PositionClosed(positionId, p.owner, price, rawPnl, pnl, fee);
    }

    function _tryLiquidate(uint256 positionId, uint256[] memory prices) internal returns (uint256 fee) {
        Position memory p = positions[positionId];
        if (!p.isOpen) return 0;

        Instrument storage instrument = instruments[p.instrumentId];
        uint256 price = _cachedPrice(prices, p.instrumentId, instrument);
        (bool liquidatable, uint256 liqPrice) = p.isLiquidatable(price, instrument.config.liquidationBuffer);
        if (!liquidatable) return 0;

        uint256 cash = _release(positionId, p);
        if (cash != 0) _settleLoss(cash);
        fee = (p.collateral * liquidationFeeRate) / WAD;
        traderStats[p.owner].recordLiquidation(p.collateral, fee);
        totalStats.recordLiquidation(p.collateral, fee);
        emit Liquidated(positionId, p.owner, price, liqPrice, fee);
    }

    function _release(uint256 positionId, Position memory p) internal returns (uint256 cash) {
        cash = p.collateral - p.debited;
        Instrument storage instrument = instruments[p.instrumentId];

        positions[positionId].isOpen = false;
        totalLockedMargin -= cash;
        instrument.decreaseOi(p.isLong, p.size());
        userOpenPositionIds[p.owner].remove(positionId);
    }

    function _cachedPrice(uint256[] memory prices, uint32 instrumentId, Instrument storage instrument)
        internal
        view
        returns (uint256)
    {
        if (prices[instrumentId] == 0) {
            prices[instrumentId] = instrument.price(pyth, maxPriceAge);
        }
        return prices[instrumentId];
    }
}
