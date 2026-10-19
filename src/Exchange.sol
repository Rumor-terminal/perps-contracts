// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {QueueLib} from "./QueueLib.sol";
import {Position, PositionLib} from "./PositionLib.sol";
import {InstrumentLib} from "./InstrumentLib.sol";
import {IExchange} from "./interfaces/IExchange.sol";

contract Exchange is IExchange, Ownable2Step {
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
        uint256 paidNow;
        uint256 profit;
        uint256 fees;
        uint256 marginReleased;
        uint256 losses;
        uint256 sideBucket;
        uint256 lossFees;
        uint256 available;
        uint256 creditLosses;
    }

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_MERGE = 64;
    uint256 public constant maxBatchClose = 25;
    uint256 internal constant MAX_FEE_RATE = 0.5e18;

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
    QueueLib.QueueState internal debtQueue;
    uint256 public totalBalances;
    uint256 public totalLockedMargin;
    uint256 public lossFeeRate = 0.02e18;
    uint256 public winFeeRate = 0.02e18;
    uint256 public liquidationFeeRate = 0.02e18;
    uint256 public protocolFeeAccumulator;
    uint256 public sideBucket;
    TradeMinimums public tradeMinimums = TradeMinimums(1e18, 0);
    bool public tradingPaused;

    constructor(address owner_, address pyth_, address collateral_) Ownable(owner_) {
        pyth = IPyth(pyth_);
        collateralToken = IERC20(collateral_);
        uint8 decimals = IERC20Metadata(collateral_).decimals();
        if (decimals > 18) revert UnsupportedCollateralDecimals();
        collateralScale = 10 ** uint256(18 - decimals);
        debtQueue.nextId = 1;
    }

    function openPosition(
        uint32 instrumentId,
        bool isLong,
        uint128 collateral,
        uint32 leverage,
        bytes[] calldata priceUpdate
    ) external payable returns (uint256 positionId) {
        uint256 fromWallet;
        (positionId, fromWallet) = _openPosition(msg.sender, instrumentId, isLong, collateral, leverage, priceUpdate);
        if (fromWallet != 0) {
            collateralToken.safeTransferFrom(msg.sender, address(this), fromWallet);
        }
    }

    function closePositions(uint256[] calldata positionIds, bytes[] calldata priceUpdate) external payable {
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

    function liquidate(uint256 positionId, bytes[] calldata priceUpdate) external payable {
        _requireTradingActive();
        _updatePyth(priceUpdate);
        Position memory p = positions[positionId];
        if (!p.isOpen) revert PositionNotOpen();
        (bool liquidatable, uint256 price, uint256 liqPrice) = _checkLiquidatable(p, _newPriceCache(0));
        if (!liquidatable) revert NotLiquidatable();
        _executeLiquidation(positionId, p, price, liqPrice);
    }

    function liquidateBatch(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        returns (uint256 liquidated)
    {
        _requireTradingActive();
        _updatePyth(priceUpdate);
        PriceCache memory cache = _newPriceCache(instrumentCount);
        for (uint256 i; i < positionIds.length; ++i) {
            if (_tryLiquidate(cache, positionIds[i])) ++liquidated;
        }
        emit LiquidationBatchProcessed(positionIds.length, liquidated);
    }

    function harvest(uint256 maxIterations) external returns (uint256 paid) {
        if (debtQueue.totalQueued == 0) revert QueueEmpty();
        uint256 available = queueHarvestAvailable();
        if (available == 0) return 0;
        (paid, totalBalances) = QueueLib.harvest(debtQueue, maxIterations, available, balances, totalBalances);
        uint256 bucket = sideBucket;
        uint256 newBucket = debtQueue.totalQueued != 0 && paid < bucket ? bucket - paid : 0;
        if (newBucket != bucket) _setSideBucket(newBucket);
    }

    function compactDebtQueue(address user, uint256 startId, uint256 maxMerges)
        external
        returns (uint256 count, uint256 amount, uint256 intoId)
    {
        return QueueLib.compactDust(debtQueue, user, startId, maxMerges, PRECISION);
    }

    function compactDebtQueueRange(address user, uint256 fromId, uint256 intoId, uint256 maxMerges)
        external
        returns (uint256 count, uint256 amount, uint256 resultId)
    {
        return QueueLib.compactDustRange(debtQueue, user, fromId, intoId, maxMerges, PRECISION);
    }

    function compactAdjacentDebtQueue(address user, uint256 startId, uint256 maxMerges)
        external
        returns (uint256 count, uint256 amount, uint256 intoId)
    {
        return QueueLib.compactAdjacent(debtQueue, user, startId, maxMerges);
    }

    function compactAdjacentDebtQueueRange(address user, uint256 fromId, uint256 toId, uint256 maxMerges)
        external
        returns (uint256 count, uint256 amount, uint256 intoId)
    {
        return QueueLib.compactAdjacentRange(debtQueue, user, fromId, toId, maxMerges);
    }

    function fundHouse(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit HouseFunded(msg.sender, amount * collateralScale);
    }

    function queueHarvestAvailable() public view returns (uint256) {
        uint256 liabilities = uint256(totalBalances) + totalLockedMargin + protocolFeeAccumulator;
        uint256 held = collateralToken.balanceOf(address(this)) * collateralScale;
        return held > liabilities ? held - liabilities : 0;
    }

    function lpBankrollAvailable() public view returns (uint256) {
        return debtQueue.totalQueued != 0 ? 0 : queueHarvestAvailable();
    }

    function totalQueued() external view returns (uint256) {
        return debtQueue.totalQueued;
    }

    function queueHead() external view returns (uint256) {
        return debtQueue.head;
    }

    function queueNextId() external view returns (uint256) {
        return debtQueue.nextId;
    }

    function userQueuedTotal(address user) external view returns (uint256) {
        return debtQueue.userQueuedTotal[user];
    }

    function userQueueHead(address user) external view returns (uint256) {
        return debtQueue.userQueueHead[user];
    }

    function userQueueTail(address user) external view returns (uint256) {
        return debtQueue.userQueueTail[user];
    }

    function queueNode(uint256 id) external view returns (address user, uint256 next, uint256 prev, uint256 amount) {
        QueueLib.Node storage n = debtQueue.nodes[id];
        return (n.user, n.next, n.prev, n.amount);
    }

    function positionOwner(uint256 positionId) external view returns (address) {
        return positions[positionId].owner;
    }

    function getUserOpenPositionIds(address user) external view returns (uint256[] memory) {
        return userOpenPositionIds[user];
    }

    function getMarketOi(uint32 instrumentId)
        external
        view
        returns (uint256 longSize, uint256 shortSize, uint256 longCap, uint256 shortCap, uint256 sizeScale)
    {
        InstrumentLib.Oi storage oi = instruments[instrumentId].oi;
        return (oi.longSize, oi.shortSize, oi.longCap, oi.shortCap, oi.sizeScale);
    }

    function liquidationPrice(uint256 positionId) external view returns (uint256) {
        Position memory p = positions[positionId];
        return p.liquidationPrice(instruments[p.instrumentId].config.liquidationBuffer);
    }

    function previewPnl(uint256 positionId, uint256 markPrice) external view returns (int256 rawPnl, int256 pnl) {
        Position memory p = positions[positionId];
        return p.pnl(markPrice, instruments[p.instrumentId].config);
    }

    function currentPrice(uint32 instrumentId) external view returns (uint256) {
        InstrumentLib.Instrument storage inst = instruments[instrumentId];
        inst.requireExists();
        return inst.price(pyth, maxPriceAge);
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
        if (lossFeeRate_ > MAX_FEE_RATE || winFeeRate_ > MAX_FEE_RATE || liquidationFeeRate_ > MAX_FEE_RATE) {
            revert FeeTooHigh();
        }
        lossFeeRate = lossFeeRate_;
        winFeeRate = winFeeRate_;
        liquidationFeeRate = liquidationFeeRate_;
        emit FeeRatesUpdated(lossFeeRate_, winFeeRate_, liquidationFeeRate_);
    }

    function setTradeMinimums(uint128 minCollateral, uint128 minNotional) external onlyOwner {
        tradeMinimums = TradeMinimums(minCollateral, minNotional);
        emit TradeMinimumsUpdated(minCollateral, minNotional);
    }

    function addInstrument(InstrumentLib.Config calldata config, uint64 sizeScale, string calldata symbol)
        external
        onlyOwner
        returns (uint32 instrumentId)
    {
        instrumentId = instrumentCount++;
        instruments[instrumentId].init(config, sizeScale);
        emit InstrumentAdded(instrumentId, config.priceId, symbol);
    }

    function setInstrumentRisk(uint32 instrumentId, uint256 maxLeverage, uint256 maxNotional) external onlyOwner {
        instruments[instrumentId].setRisk(maxLeverage, maxNotional);
        emit InstrumentRiskUpdated(instrumentId, maxLeverage, maxNotional);
    }

    function setInstrumentImpactConfig(
        uint32 instrumentId,
        uint256 impactC,
        uint256 impactB,
        uint256 impactA,
        uint256 profitHaircut
    ) external onlyOwner {
        instruments[instrumentId].setImpactConfig(impactC, impactB, impactA, profitHaircut);
        emit InstrumentImpactConfigUpdated(instrumentId, impactC, impactB, impactA, profitHaircut);
    }

    function setMarketOiCaps(uint32 instrumentId, uint96 longCap, uint96 shortCap) external onlyOwner {
        instruments[instrumentId].setOiCaps(longCap, shortCap);
        emit MarketOiCapsUpdated(instrumentId, longCap, shortCap);
    }

    receive() external payable {}

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function claimProtocolFees() external onlyOwner {
        uint256 amount = protocolFeeAccumulator;
        if (amount == 0) return;
        protocolFeeAccumulator = 0;
        uint256 paid = _payOrQueue(msg.sender, amount);
        emit ProtocolFeesClaimed(msg.sender, amount, paid);
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
        uint256 price = _checkOpenParams(inst, collateral, leverage);
        bool useCredits;
        (fromWallet, useCredits) = _lockMargin(trader, collateral);
        if (debtQueue.totalQueued == 0 && sideBucket != 0) _setSideBucket(0);

        Position memory p = Position({
            owner: trader,
            instrumentId: instrumentId,
            entryPrice: price.toUint64(),
            collateral: collateral,
            leverage: leverage,
            openedAt: uint64(block.timestamp),
            isLong: isLong,
            usedCredits: useCredits,
            isOpen: true
        });
        inst.increaseOi(isLong, p.size(inst.oi.sizeScale));
        positionId = nextPositionId++;
        positions[positionId] = p;
        uint256[] storage ids = userOpenPositionIds[trader];
        ids.push(positionId);
        positionIndex[positionId] = ids.length;
        emit PositionOpened(positionId, trader, instrumentId, isLong, useCredits, p.entryPrice, collateral, leverage);
    }

    function _checkOpenParams(InstrumentLib.Instrument storage inst, uint256 collateral, uint256 leverage)
        internal
        view
        returns (uint256)
    {
        uint256 notional = inst.checkOpen(collateral, leverage);
        TradeMinimums memory minimums = tradeMinimums;
        if (collateral < minimums.minCollateral) revert TradeBelowMinimum();
        if (notional < minimums.minNotional) revert NotionalBelowMinimum();
        return inst.price(pyth, maxPriceAge);
    }

    function _lockMargin(address trader, uint256 collateral) internal returns (uint256 fromWallet, bool usedCredits) {
        if (debtQueue.userQueuedTotal[trader] >= collateral) {
            QueueLib.consume(debtQueue, trader, collateral);
            return (0, true);
        }
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

    function _closePositions(address trader, uint256[] calldata positionIds, bytes[] calldata priceUpdate) internal {
        _requireTradingActive();
        _updatePyth(priceUpdate);
        uint256 count = positionIds.length;
        if (count == 0) revert EmptyCloseList();
        if (count > maxBatchClose) revert TooManyPositions();

        CloseTotals memory totals;
        totals.available = lpBankrollAvailable();
        PriceCache memory cache = _newPriceCache(instrumentCount);
        bool closedAny;
        for (uint256 i; i < count; ++i) {
            uint256 positionId = positionIds[i];
            Position memory p = positions[positionId];
            if (!p.isOpen || p.owner != trader) continue;
            closedAny = true;
            _closePosition(trader, positionId, p, cache, totals);
        }
        if (closedAny) _applyCloseTotals(trader, totals);
    }

    function _closePosition(
        address trader,
        uint256 positionId,
        Position memory p,
        PriceCache memory cache,
        CloseTotals memory totals
    ) internal {
        if (!p.isOpen) revert PositionNotOpen();
        if (p.owner != trader) revert NotPositionOwner();
        InstrumentLib.Instrument storage inst = instruments[p.instrumentId];
        uint256 price = _cachedPrice(cache, p.instrumentId, inst);
        positions[positionId].isOpen = false;
        if (!p.usedCredits) totals.marginReleased += p.collateral;
        inst.decreaseOi(p.isLong, p.size(inst.oi.sizeScale));
        (int256 rawPnl, int256 pnl) = p.pnl(price, inst.config);
        _removeUserPosition(trader, positionId);
        uint256 fees = _settleClose(trader, p.collateral, pnl, p.usedCredits, totals);
        emit PositionClosed(positionId, trader, price, rawPnl, pnl, p.usedCredits, fees);
    }

    function _settleClose(address trader, uint256 collateral, int256 pnl, bool usedCredits, CloseTotals memory totals)
        internal
        returns (uint256 fees)
    {
        QueueLib.Settlement memory st =
            QueueLib.settle(debtQueue, trader, collateral, pnl, usedCredits, winFeeRate, lossFeeRate, totals.available);
        totals.marginReturned += st.marginReturned;
        totals.paidNow += st.paidNow;
        totals.sideBucket += st.toSideBucket;
        fees = st.stakerFee + st.devFee;
        totals.fees += fees;
        _trackAvailable(
            totals, usedCredits ? 0 : collateral, st.marginReturned + st.paidNow + st.queued + st.toSideBucket + fees
        );

        if (pnl > 0) {
            totals.profit += st.marginReturned + st.paidNow + st.queued - collateral + fees;
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            if (usedCredits) {
                totals.creditLosses += (loss < collateral ? loss : collateral) - fees;
            } else {
                totals.losses += loss;
                totals.lossFees += fees;
            }
        }
    }

    function _trackAvailable(CloseTotals memory totals, uint256 inflow, uint256 outflow) internal pure {
        if (inflow >= outflow) {
            totals.available += inflow - outflow;
        } else {
            uint256 drain = outflow - inflow;
            totals.available = totals.available > drain ? totals.available - drain : 0;
        }
    }

    function _applyCloseTotals(address trader, CloseTotals memory totals) internal {
        if (totals.marginReleased != 0) {
            totalLockedMargin -= totals.marginReleased;
        }
        uint256 credited = totals.marginReturned + totals.paidNow;
        if (credited != 0) _creditBalance(trader, credited);
        if (totals.fees != 0) protocolFeeAccumulator += totals.fees;
        if (totals.sideBucket != 0) {
            _setSideBucket(sideBucket + totals.sideBucket);
        }
        emit PositionsClosed(trader, credited, balances[trader], totals.fees);
    }

    function _tryLiquidate(PriceCache memory cache, uint256 positionId) internal returns (bool) {
        Position memory p = positions[positionId];
        if (!p.isOpen) return false;
        (bool liquidatable, uint256 price, uint256 liqPrice) = _checkLiquidatable(p, cache);
        if (!liquidatable) return false;
        _executeLiquidation(positionId, p, price, liqPrice);
        return true;
    }

    function _checkLiquidatable(Position memory p, PriceCache memory cache)
        internal
        view
        returns (bool liquidatable, uint256 price, uint256 liqPrice)
    {
        InstrumentLib.Instrument storage inst = instruments[p.instrumentId];
        price = _cachedPrice(cache, p.instrumentId, inst);
        (liquidatable, liqPrice) = p.isLiquidatable(price, inst.config.liquidationBuffer);
    }

    function _executeLiquidation(uint256 positionId, Position memory p, uint256 price, uint256 liqPrice) internal {
        positions[positionId].isOpen = false;
        address trader = p.owner;
        _removeUserPosition(trader, positionId);
        uint256 collateral = p.collateral;
        InstrumentLib.Instrument storage inst = instruments[p.instrumentId];
        inst.decreaseOi(p.isLong, p.size(inst.oi.sizeScale));

        uint256 fee;
        bool usedCredits = p.usedCredits;
        if (!usedCredits) {
            totalLockedMargin -= collateral;
            if (debtQueue.totalQueued == 0) {
                fee = (collateral * liquidationFeeRate) / PRECISION;
                if (fee != 0) protocolFeeAccumulator += fee;
            } else {
                _setSideBucket(sideBucket + collateral);
            }
        }
        emit Liquidated(positionId, trader, price, liqPrice, usedCredits, fee);
    }

    function _payOrQueue(address user, uint256 amount) internal returns (uint256 paid) {
        uint256 available = lpBankrollAvailable();
        paid = amount < available ? amount : available;
        if (paid != 0) _creditBalance(user, paid);
        if (paid < amount) QueueLib.enqueue(debtQueue, user, amount - paid);
    }

    function _creditBalance(address user, uint256 amount) internal {
        balances[user] += amount;
        totalBalances += amount;
    }

    function _setSideBucket(uint256 value) internal {
        sideBucket = value;
        emit SideBucketUpdated(value);
    }

    function _newPriceCache(uint256 length) internal pure returns (PriceCache memory) {
        return PriceCache(new uint256[](length), new bool[](length));
    }

    function _cachedPrice(PriceCache memory cache, uint32 instrumentId, InstrumentLib.Instrument storage inst)
        internal
        view
        returns (uint256)
    {
        if (instrumentId >= cache.loaded.length || instrumentId >= cache.prices.length) {
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
