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
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {QueueLib} from "./QueueLib.sol";
import {IExchange} from "./interfaces/IExchange.sol";

contract Exchange is IExchange, Ownable2Step {
    using SafeERC20 for IERC20;

    struct PriceCache {
        uint64[] prices;
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
    int32 internal constant PRICE_EXPO = -8;

    IPyth public immutable pyth;
    IERC20 public immutable collateralToken;
    uint256 public immutable collateralScale;

    uint256 public maxPriceAge = 60;
    mapping(uint32 => Instrument) public instruments;
    uint32 public instrumentCount;
    mapping(address => uint256) public balances;
    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;
    mapping(address => uint256[]) internal userOpenPositionIds;
    mapping(uint256 => uint256) public positionIndex;
    QueueLib.QueueState internal debtQueue;
    uint128 public totalBalances;
    uint128 public totalLockedMargin;
    uint256 public lossFeeRate = 0.02e18;
    uint256 public winFeeRate = 0.02e18;
    uint256 public liquidationFeeRate = 0.02e18;
    uint128 public protocolFeeAccumulator;
    uint128 public sideBucket;
    TradeMinimums public tradeMinimums = TradeMinimums(1e18, 0);
    bool public tradingPaused;
    mapping(uint32 => MarketPause) public marketPause;
    mapping(uint32 => MarketOi) public marketOi;

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
        (positionId, fromWallet) = _openPosition(
            msg.sender,
            instrumentId,
            isLong,
            collateral,
            leverage,
            priceUpdate
        );
        if (fromWallet != 0)
            collateralToken.safeTransferFrom(
                msg.sender,
                address(this),
                fromWallet
            );
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
        totalBalances -= uint128(debit);
        collateralToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, debit);
    }

    function liquidate(
        uint256 positionId,
        bytes[] calldata priceUpdate
    ) external payable {
        _updatePyth(priceUpdate);
        Position storage p = positions[positionId];
        if (!p.isOpen) revert PositionNotOpen();
        (bool liquidatable, uint64 price, uint64 liqPrice) = _checkLiquidatable(
            p,
            _newPriceCache(0)
        );
        if (!liquidatable) revert NotLiquidatable();
        _executeLiquidation(positionId, p, price, liqPrice);
    }

    function liquidateBatch(
        uint256[] calldata positionIds,
        bytes[] calldata priceUpdate
    ) external payable returns (uint256 liquidated) {
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
        uint256 newTotalBalances;
        (paid, newTotalBalances) = QueueLib.harvest(
            debtQueue,
            maxIterations,
            available,
            balances,
            totalBalances
        );
        totalBalances = uint128(newTotalBalances);
        uint128 bucket = sideBucket;
        uint128 newBucket = debtQueue.totalQueued != 0 && paid < bucket
            ? bucket - uint128(paid)
            : 0;
        if (newBucket != bucket) _setSideBucket(newBucket);
    }

    function compactDebtQueue(
        address user,
        uint256 startId,
        uint256 maxMerges
    ) external returns (uint256 count, uint256 amount, uint256 intoId) {
        return
            QueueLib.compactDust(
                debtQueue,
                user,
                startId,
                maxMerges,
                PRECISION
            );
    }

    function compactDebtQueueRange(
        address user,
        uint256 fromId,
        uint256 intoId,
        uint256 maxMerges
    ) external returns (uint256 count, uint256 amount, uint256 resultId) {
        return
            QueueLib.compactDustRange(
                debtQueue,
                user,
                fromId,
                intoId,
                maxMerges,
                PRECISION
            );
    }

    function compactAdjacentDebtQueue(
        address user,
        uint256 startId,
        uint256 maxMerges
    ) external returns (uint256 count, uint256 amount, uint256 intoId) {
        return QueueLib.compactAdjacent(debtQueue, user, startId, maxMerges);
    }

    function compactAdjacentDebtQueueRange(
        address user,
        uint256 fromId,
        uint256 toId,
        uint256 maxMerges
    ) external returns (uint256 count, uint256 amount, uint256 intoId) {
        return
            QueueLib.compactAdjacentRange(
                debtQueue,
                user,
                fromId,
                toId,
                maxMerges
            );
    }

    function fundHouse(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit HouseFunded(msg.sender, amount * collateralScale);
    }

    function queueHarvestAvailable() public view returns (uint256) {
        uint256 liabilities = uint256(totalBalances) +
            totalLockedMargin +
            protocolFeeAccumulator;
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

    function queueNode(
        uint256 id
    )
        external
        view
        returns (address user, uint48 next, uint48 prev, uint256 amount)
    {
        QueueLib.Node storage n = debtQueue.nodes[id];
        return (n.user, n.next, n.prev, n.amount);
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
            uint96 longSize,
            uint96 shortSize,
            uint128 longCap,
            uint128 shortCap,
            uint64 sizeScale
        )
    {
        MarketOi storage oi = marketOi[instrumentId];
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
    ) external view returns (uint64) {
        Position storage p = positions[positionId];
        return
            _liquidationPrice(
                p.entryPrice,
                p.leverage,
                instruments[p.instrumentId].liquidationBuffer,
                p.isLong
            );
    }

    function previewLiquidationPrice(
        uint32 instrumentId,
        uint64 entryPrice,
        uint32 leverage,
        bool isLong
    ) external view returns (uint64) {
        return
            _liquidationPrice(
                entryPrice,
                leverage,
                instruments[instrumentId].liquidationBuffer,
                isLong
            );
    }

    function previewPnl(
        uint256 positionId,
        uint64 markPrice
    ) external view returns (int256 rawPnl, int256 pnl) {
        return _positionPnl(positions[positionId], markPrice);
    }

    function currentPrice(uint32 instrumentId) external view returns (uint64) {
        _requireInstrument(instrumentId);
        return _price(instrumentId, instruments[instrumentId].priceId);
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
        if (
            lossFeeRate_ > MAX_FEE_RATE ||
            winFeeRate_ > MAX_FEE_RATE ||
            liquidationFeeRate_ > MAX_FEE_RATE
        ) {
            revert FeeTooHigh();
        }
        lossFeeRate = lossFeeRate_;
        winFeeRate = winFeeRate_;
        liquidationFeeRate = liquidationFeeRate_;
        emit FeeRatesUpdated(lossFeeRate_, winFeeRate_, liquidationFeeRate_);
    }

    function setTradeMinimums(
        uint128 minCollateral,
        uint128 minNotional
    ) external onlyOwner {
        tradeMinimums = TradeMinimums(minCollateral, minNotional);
        emit TradeMinimumsUpdated(minCollateral, minNotional);
    }

    function addInstrument(
        Instrument calldata config,
        uint64 sizeScale,
        string calldata symbol
    ) external onlyOwner returns (uint32 instrumentId) {
        if (config.maxLeverage == 0) revert InvalidInstrumentConfig();
        if (config.liquidationBuffer >= PRECISION)
            revert InvalidInstrumentConfig();
        if (config.profitHaircut >= PRECISION) revert InvalidInstrumentConfig();
        if (config.impactA == 0) revert InvalidInstrumentConfig();
        if (config.impactC == 0) revert InvalidInstrumentConfig();
        if (config.maxNotional == 0) revert InvalidInstrumentConfig();
        if (config.priceId == bytes32(0)) revert InvalidInstrumentConfig();
        if (sizeScale == 0) revert InvalidSizeScale();
        instrumentId = instrumentCount++;
        instruments[instrumentId] = config;
        MarketOi storage oi = marketOi[instrumentId];
        oi.sizeScale = sizeScale;
        oi.longCap = type(uint128).max;
        oi.shortCap = type(uint128).max;
        emit InstrumentAdded(instrumentId, config.priceId, symbol);
    }

    function setInstrumentRisk(
        uint32 instrumentId,
        uint32 maxLeverage,
        uint256 maxNotional
    ) external onlyOwner {
        _requireInstrument(instrumentId);
        if (
            maxLeverage == 0 ||
            maxNotional == 0 ||
            maxNotional > type(uint120).max
        ) revert InvalidInstrumentConfig();
        Instrument storage inst = instruments[instrumentId];
        inst.maxLeverage = maxLeverage;
        inst.maxNotional = uint120(maxNotional);
        emit InstrumentRiskUpdated(instrumentId, maxLeverage, maxNotional);
    }

    function setInstrumentImpactConfig(
        uint32 instrumentId,
        uint128 impactC,
        uint96 impactB,
        uint96 impactA,
        uint64 profitHaircut
    ) external onlyOwner {
        _requireInstrument(instrumentId);
        if (impactC == 0 || impactA == 0 || profitHaircut >= PRECISION)
            revert InvalidInstrumentConfig();
        Instrument storage inst = instruments[instrumentId];
        inst.impactC = impactC;
        inst.impactB = impactB;
        inst.impactA = impactA;
        inst.profitHaircut = profitHaircut;
        emit InstrumentImpactConfigUpdated(
            instrumentId,
            impactC,
            impactB,
            impactA,
            profitHaircut
        );
    }

    function setMarketOiCaps(
        uint32 instrumentId,
        uint128 longCap,
        uint128 shortCap
    ) external onlyOwner {
        _requireInstrument(instrumentId);
        MarketOi storage oi = marketOi[instrumentId];
        oi.longCap = longCap;
        oi.shortCap = shortCap;
        emit MarketOiCapsUpdated(instrumentId, longCap, shortCap);
    }

    function pauseMarket(
        uint32 instrumentId,
        bytes[] calldata priceUpdate
    ) external payable onlyOwner {
        _requireInstrument(instrumentId);
        MarketPause storage mp = marketPause[instrumentId];
        if (mp.paused) revert MarketAlreadyPaused();
        _updatePyth(priceUpdate);
        (uint64 bid, uint64 ask) = _bidAsk(instruments[instrumentId].priceId);
        mp.paused = true;
        mp.bid = bid;
        mp.ask = ask;
        mp.pausedAt = uint64(block.timestamp);
        emit MarketPaused(instrumentId, bid, ask, uint64(block.timestamp));
    }

    function unpauseMarket(uint32) external pure {
        revert UnpauseDisabled();
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
        uint256 paid = _payOrQueue(msg.sender, amount);
        emit ProtocolFeesClaimed(msg.sender, amount, paid);
    }

    function _updatePyth(bytes[] calldata priceUpdate) internal {
        if (priceUpdate.length == 0) return;
        uint256 fee = pyth.getUpdateFee(priceUpdate);
        if (address(this).balance < fee) revert InsufficientUpdateFee();
        pyth.updatePriceFeeds{value: fee}(priceUpdate);
    }

    function _normalizePrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint64) {
        if (price <= 0) revert InvalidPrice();
        uint256 value = uint256(uint64(price));
        if (expo < PRICE_EXPO) {
            value /= 10 ** uint256(uint32(PRICE_EXPO - expo));
        } else if (expo > PRICE_EXPO) {
            value *= 10 ** uint256(uint32(expo - PRICE_EXPO));
        }
        if (value == 0 || value > type(uint64).max) revert InvalidPrice();
        return uint64(value);
    }

    function _pythPrice(
        bytes32 priceId
    ) internal view returns (PythStructs.Price memory) {
        return pyth.getPriceNoOlderThan(priceId, maxPriceAge);
    }

    function _bidAsk(
        bytes32 priceId
    ) internal view returns (uint64 bid, uint64 ask) {
        PythStructs.Price memory p = _pythPrice(priceId);
        uint64 mid = _normalizePrice(p.price, p.expo);
        uint64 conf = uint64(p.conf) > 0
            ? _normalizePrice(int64(p.conf), p.expo)
            : 0;
        bid = conf < mid ? mid - conf : 0;
        ask = mid + conf;
    }

    function _openPosition(
        address trader,
        uint32 instrumentId,
        bool isLong,
        uint128 collateral,
        uint32 leverage,
        bytes[] calldata priceUpdate
    ) internal returns (uint256 positionId, uint256 fromWallet) {
        if (tradingPaused) revert TradingPaused();
        _updatePyth(priceUpdate);
        uint64 price = _checkOpenParams(instrumentId, collateral, leverage);
        _increaseOi(
            instrumentId,
            isLong,
            _positionSize(
                uint256(collateral) * leverage,
                marketOi[instrumentId].sizeScale,
                price
            )
        );
        bool useCredits;
        (fromWallet, useCredits) = _lockMargin(trader, collateral);
        if (debtQueue.totalQueued == 0 && sideBucket != 0) _setSideBucket(0);

        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner: trader,
            instrumentId: instrumentId,
            entryPrice: price,
            collateral: collateral,
            leverage: leverage,
            openedAt: uint64(block.timestamp),
            isLong: isLong,
            usedCredits: useCredits,
            isOpen: true
        });
        uint256[] storage ids = userOpenPositionIds[trader];
        ids.push(positionId);
        positionIndex[positionId] = ids.length;
        emit PositionOpened(
            positionId,
            trader,
            instrumentId,
            isLong,
            useCredits,
            price,
            collateral,
            leverage
        );
    }

    function _checkOpenParams(
        uint32 instrumentId,
        uint128 collateral,
        uint32 leverage
    ) internal view returns (uint64) {
        _requireInstrument(instrumentId);
        Instrument storage inst = instruments[instrumentId];
        if (marketPause[instrumentId].paused) revert MarketIsPaused();
        if (leverage == 0) revert LeverageTooLow();
        if (leverage > inst.maxLeverage) revert LeverageTooHigh();
        TradeMinimums memory minimums = tradeMinimums;
        if (collateral < minimums.minCollateral) revert TradeBelowMinimum();
        uint256 notional = uint256(collateral) * leverage;
        if (notional < minimums.minNotional) revert NotionalBelowMinimum();
        if (notional > inst.maxNotional) revert PositionTooLarge();
        return _price(instrumentId, inst.priceId);
    }

    function _increaseOi(
        uint32 instrumentId,
        bool isLong,
        uint96 size
    ) internal {
        MarketOi storage oi = marketOi[instrumentId];
        if (isLong) {
            uint96 newLong = oi.longSize + size;
            if (newLong > oi.longCap) revert OiCapExceeded();
            oi.longSize = newLong;
        } else {
            uint96 newShort = oi.shortSize + size;
            if (newShort > oi.shortCap) revert OiCapExceeded();
            oi.shortSize = newShort;
        }
    }

    function _lockMargin(
        address trader,
        uint128 collateral
    ) internal returns (uint256 fromWallet, bool usedCredits) {
        if (debtQueue.userQueuedTotal[trader] >= collateral) {
            QueueLib.consume(debtQueue, trader, collateral);
            return (0, true);
        }
        uint256 balance = balances[trader];
        uint256 fromBalance = balance < collateral ? balance : collateral;
        fromBalance -= fromBalance % collateralScale;
        if (fromBalance != 0) {
            balances[trader] = balance - fromBalance;
            totalBalances -= uint128(fromBalance);
        }
        uint256 remaining = uint256(collateral) - fromBalance;
        if (remaining != 0) {
            fromWallet = remaining / collateralScale;
            if (fromWallet * collateralScale != remaining)
                revert CollateralPrecision();
        }
        totalLockedMargin += collateral;
    }

    function _closePositions(
        address trader,
        uint256[] calldata positionIds,
        bytes[] calldata priceUpdate
    ) internal {
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
            Position storage p = positions[positionId];
            if (!p.isOpen || p.owner != trader) continue;
            closedAny = true;
            _closePosition(trader, positionId, p, cache, totals);
        }
        if (closedAny) _applyCloseTotals(trader, totals);
    }

    function _closePosition(
        address trader,
        uint256 positionId,
        Position storage p,
        PriceCache memory cache,
        CloseTotals memory totals
    ) internal {
        if (!p.isOpen) revert PositionNotOpen();
        if (p.owner != trader) revert NotPositionOwner();
        uint64 price = _cachedPrice(
            cache,
            p.instrumentId,
            instruments[p.instrumentId].priceId
        );
        p.isOpen = false;
        if (!p.usedCredits) totals.marginReleased += p.collateral;
        _decreaseOi(
            p.instrumentId,
            p.isLong,
            _positionSize(
                uint256(p.collateral) * p.leverage,
                marketOi[p.instrumentId].sizeScale,
                p.entryPrice
            )
        );
        (int256 rawPnl, int256 pnl) = _positionPnl(p, price);
        _removeUserPosition(trader, positionId);
        uint256 fees = _settleClose(
            trader,
            p.collateral,
            pnl,
            p.usedCredits,
            totals
        );
        emit PositionClosed(
            positionId,
            trader,
            price,
            rawPnl,
            pnl,
            p.usedCredits,
            fees
        );
    }

    function _positionPnl(
        Position storage p,
        uint64 price
    ) internal view returns (int256 rawPnl, int256 pnl) {
        Instrument storage inst = instruments[p.instrumentId];
        return
            QueueLib.computePositionPnl(
                p.entryPrice,
                price,
                p.collateral,
                p.leverage,
                p.isLong,
                inst.profitHaircut,
                inst.impactA,
                inst.impactB,
                inst.impactC
            );
    }

    function _settleClose(
        address trader,
        uint128 collateral,
        int256 pnl,
        bool usedCredits,
        CloseTotals memory totals
    ) internal returns (uint256 fees) {
        QueueLib.Settlement memory st = QueueLib.settle(
            debtQueue,
            trader,
            collateral,
            pnl,
            usedCredits,
            winFeeRate,
            lossFeeRate,
            totals.available
        );
        totals.marginReturned += st.marginReturned;
        totals.paidNow += st.paidNow;
        totals.sideBucket += st.toSideBucket;
        fees = st.stakerFee + st.devFee;
        totals.fees += fees;
        _trackAvailable(
            totals,
            usedCredits ? 0 : collateral,
            st.marginReturned + st.paidNow + st.queued + st.toSideBucket + fees
        );

        if (pnl > 0) {
            totals.profit +=
                st.marginReturned +
                st.paidNow +
                st.queued -
                collateral +
                fees;
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            if (usedCredits) {
                totals.creditLosses +=
                    (loss < collateral ? loss : collateral) -
                    fees;
            } else {
                totals.losses += loss;
                totals.lossFees += fees;
            }
        }
    }

    function _trackAvailable(
        CloseTotals memory totals,
        uint256 inflow,
        uint256 outflow
    ) internal pure {
        if (inflow >= outflow) {
            totals.available += inflow - outflow;
        } else {
            uint256 drain = outflow - inflow;
            totals.available = totals.available > drain
                ? totals.available - drain
                : 0;
        }
    }

    function _applyCloseTotals(
        address trader,
        CloseTotals memory totals
    ) internal {
        if (totals.marginReleased != 0)
            totalLockedMargin -= uint128(totals.marginReleased);
        uint256 credited = totals.marginReturned + totals.paidNow;
        if (credited != 0) _creditBalance(trader, credited);
        if (totals.fees != 0) protocolFeeAccumulator += uint128(totals.fees);
        if (totals.sideBucket != 0)
            _setSideBucket(sideBucket + uint128(totals.sideBucket));
        emit PositionsClosed(trader, credited, balances[trader], totals.fees);
    }

    function _tryLiquidate(
        PriceCache memory cache,
        uint256 positionId
    ) internal returns (bool) {
        Position storage p = positions[positionId];
        if (!p.isOpen) return false;
        (bool liquidatable, uint64 price, uint64 liqPrice) = _checkLiquidatable(
            p,
            cache
        );
        if (!liquidatable) return false;
        _executeLiquidation(positionId, p, price, liqPrice);
        return true;
    }

    function _checkLiquidatable(
        Position storage p,
        PriceCache memory cache
    ) internal view returns (bool liquidatable, uint64 price, uint64 liqPrice) {
        Instrument storage inst = instruments[p.instrumentId];
        price = _cachedPrice(cache, p.instrumentId, inst.priceId);
        liqPrice = _liquidationPrice(
            p.entryPrice,
            p.leverage,
            inst.liquidationBuffer,
            p.isLong
        );
        liquidatable = p.isLong ? price <= liqPrice : price >= liqPrice;
    }

    function _executeLiquidation(
        uint256 positionId,
        Position storage p,
        uint64 price,
        uint64 liqPrice
    ) internal {
        p.isOpen = false;
        address trader = p.owner;
        _removeUserPosition(trader, positionId);
        uint128 collateral = p.collateral;
        uint32 instrumentId = p.instrumentId;
        _decreaseOi(
            instrumentId,
            p.isLong,
            _positionSize(
                uint256(collateral) * p.leverage,
                marketOi[instrumentId].sizeScale,
                p.entryPrice
            )
        );

        uint256 fee;
        bool usedCredits = p.usedCredits;
        if (!usedCredits) {
            totalLockedMargin -= collateral;
            if (debtQueue.totalQueued == 0) {
                fee = (uint256(collateral) * liquidationFeeRate) / PRECISION;
                if (fee != 0) protocolFeeAccumulator += uint128(fee);
            } else {
                _setSideBucket(sideBucket + collateral);
            }
        }
        emit Liquidated(positionId, trader, price, liqPrice, usedCredits, fee);
    }

    function _payOrQueue(
        address user,
        uint256 amount
    ) internal returns (uint256 paid) {
        uint256 available = lpBankrollAvailable();
        paid = amount < available ? amount : available;
        if (paid != 0) _creditBalance(user, paid);
        if (paid < amount) QueueLib.enqueue(debtQueue, user, amount - paid);
    }

    function _creditBalance(address user, uint256 amount) internal {
        balances[user] += amount;
        totalBalances += uint128(amount);
    }

    function _setSideBucket(uint128 value) internal {
        sideBucket = value;
        emit SideBucketUpdated(value);
    }

    function _requireInstrument(uint32 instrumentId) internal view {
        if (instrumentId >= instrumentCount) revert InvalidInstrumentId();
    }

    function _price(
        uint32 instrumentId,
        bytes32 priceId
    ) internal view returns (uint64) {
        MarketPause storage mp = marketPause[instrumentId];
        if (mp.paused) return uint64((uint256(mp.bid) + mp.ask) >> 1);
        PythStructs.Price memory p = _pythPrice(priceId);
        return _normalizePrice(p.price, p.expo);
    }

    function _newPriceCache(
        uint256 length
    ) internal pure returns (PriceCache memory) {
        return PriceCache(new uint64[](length), new bool[](length));
    }

    function _cachedPrice(
        PriceCache memory cache,
        uint32 instrumentId,
        bytes32 priceId
    ) internal view returns (uint64) {
        if (
            instrumentId >= cache.loaded.length ||
            instrumentId >= cache.prices.length
        ) {
            return _price(instrumentId, priceId);
        }
        if (!cache.loaded[instrumentId]) {
            cache.prices[instrumentId] = _price(instrumentId, priceId);
            cache.loaded[instrumentId] = true;
        }
        return cache.prices[instrumentId];
    }

    function _liquidationPrice(
        uint64 entryPrice,
        uint32 leverage,
        uint64 buffer,
        bool isLong
    ) internal pure returns (uint64) {
        uint256 step = entryPrice / leverage;
        if (isLong) {
            uint256 base = entryPrice - step;
            return uint64(base + (base * buffer) / PRECISION);
        }
        uint256 shortBase = entryPrice + step;
        return uint64(shortBase - (shortBase * buffer) / PRECISION);
    }

    function _positionSize(
        uint256 notional,
        uint64 sizeScale,
        uint64 price
    ) internal pure returns (uint96) {
        if (sizeScale == 0) revert InvalidSizeScale();
        uint256 size = (notional * sizeScale) / price;
        if (size > type(uint96).max) revert SizeOverflow();
        return uint96(size);
    }

    function _decreaseOi(
        uint32 instrumentId,
        bool isLong,
        uint96 size
    ) internal {
        MarketOi storage oi = marketOi[instrumentId];
        if (isLong) oi.longSize -= size;
        else oi.shortSize -= size;
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
