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

struct Settlement {
    uint256 returned;
    uint256 owed;
    uint256 lost;
    uint256 fee;
}

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
    mapping(address => EnumerableSet.UintSet) internal openPositionIdsOf;
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
            trader: msg.sender,
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
        openPositionIdsOf[msg.sender].add(positionId);

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
        Settlement memory total;
        for (uint256 i; i < positionIds.length; ++i) {
            Settlement memory s = _tryClose(positionIds[i], prices);
            total.returned += s.returned;
            total.owed += s.owed;
            total.lost += s.lost;
            total.fee += s.fee;
        }

        _settleNet(msg.sender, total);
        _payFee(owner(), total.fee);
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

    function openPositionIds(address trader) external view returns (uint256[] memory) {
        return openPositionIdsOf[trader].values();
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

    function _settleNet(address trader, Settlement memory s) internal {
        if (s.owed > s.lost) {
            _settleWin(trader, s.owed - s.lost);
        } else {
            _settleLoss(s.lost - s.owed);
        }

        uint256 direct = s.returned + Math.min(s.owed, s.lost);
        if (direct != 0) _pay(trader, direct);
    }

    function _tryClose(uint256 positionId, uint256[] memory prices) internal returns (Settlement memory s) {
        Position memory p = positions[positionId];
        if (!p.isOpen || p.trader != msg.sender) return s;

        Instrument storage instrument = instruments[p.instrumentId];
        uint256 price = _cachedPrice(prices, p.instrumentId, instrument);
        uint256 cash = _release(positionId, p);

        (int256 rawPnl, int256 pnl) = p.pnl(price, instrument.config);
        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            s.fee = (profit * winFeeRate) / WAD;
            s.returned = cash;
            s.owed = p.debited + profit - s.fee;
        } else {
            uint256 loss = uint256(-pnl);
            s.fee = (loss * lossFeeRate) / WAD;
            uint256 lossFromDebit = Math.min(loss, p.debited);
            s.lost = loss - lossFromDebit;
            s.returned = cash - s.lost;
            s.owed = p.debited - lossFromDebit;
        }
        traderStats[p.trader].recordClose(pnl, s.fee);
        totalStats.recordClose(pnl, s.fee);
        emit PositionClosed(positionId, p.trader, price, rawPnl, pnl, s.fee);
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
        traderStats[p.trader].recordLiquidation(p.collateral, fee);
        totalStats.recordLiquidation(p.collateral, fee);
        emit Liquidated(positionId, p.trader, price, liqPrice, fee);
    }

    function _release(uint256 positionId, Position memory p) internal returns (uint256 cash) {
        cash = p.collateral - p.debited;
        Instrument storage instrument = instruments[p.instrumentId];

        positions[positionId].isOpen = false;
        totalLockedMargin -= cash;
        instrument.decreaseOi(p.isLong, p.size());
        openPositionIdsOf[p.trader].remove(positionId);
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
