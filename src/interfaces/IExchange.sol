// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {InstrumentLib} from "../InstrumentLib.sol";

interface IExchange {
    struct TradeMinimums {
        uint128 minCollateral;
        uint128 minNotional;
    }

    error UnsupportedCollateralDecimals();
    error FeeTooHigh();
    error TradingPaused();
    error TradeBelowMinimum();
    error NotionalBelowMinimum();
    error InsufficientBalance();
    error PositionNotOpen();
    error NotPositionOwner();
    error NotLiquidatable();
    error EmptyCloseList();
    error TooManyPositions();
    error QueueEmpty();
    error CollateralPrecision();
    error ZeroAmount();
    error InsufficientUpdateFee();
    error NativeTransferFailed();

    event TradingPausedUpdated(bool paused);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event FeeRatesUpdated(uint256 lossFeeRate, uint256 winFeeRate, uint256 liquidationFeeRate);
    event TradeMinimumsUpdated(uint128 minCollateral, uint128 minNotional);
    event InstrumentAdded(uint32 indexed instrumentId, bytes32 priceId, string symbol);
    event InstrumentRiskUpdated(uint32 indexed instrumentId, uint256 maxLeverage, uint256 maxNotional);
    event InstrumentImpactConfigUpdated(
        uint32 indexed instrumentId, uint256 impactC, uint256 impactB, uint256 impactA, uint256 profitHaircut
    );
    event MarketOiCapsUpdated(uint32 indexed instrumentId, uint96 longCap, uint96 shortCap);
    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        uint32 instrumentId,
        bool isLong,
        bool usedCredits,
        uint64 entryPrice,
        uint128 collateral,
        uint32 leverage
    );
    event PositionClosed(
        uint256 indexed positionId,
        address indexed trader,
        uint256 exitPrice,
        int256 rawPnl,
        int256 pnl,
        bool usedCredits,
        uint256 fees
    );
    event PositionsClosed(address indexed trader, uint256 credited, uint256 newBalance, uint256 fees);
    event Liquidated(
        uint256 indexed positionId,
        address indexed trader,
        uint256 price,
        uint256 liquidationPrice,
        bool usedCredits,
        uint256 fee
    );
    event LiquidationBatchProcessed(uint256 requested, uint256 liquidated);
    event SideBucketUpdated(uint256 sideBucket);
    event Claimed(address indexed user, uint256 amount);
    event HouseFunded(address indexed from, uint256 amount);
    event ProtocolFeesClaimed(address indexed recipient, uint256 amount, uint256 paid);

    function claim(uint256 amount) external;

    function fundHouse(uint256 amount) external;

    function openPosition(
        uint32 instrumentId,
        bool isLong,
        uint128 collateral,
        uint32 leverage,
        bytes[] calldata priceUpdate
    ) external payable returns (uint256 positionId);

    function closePositions(uint256[] calldata positionIds, bytes[] calldata priceUpdate) external payable;

    function liquidate(uint256 positionId, bytes[] calldata priceUpdate) external payable;

    function liquidateBatch(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        returns (uint256 liquidated);

    function harvest(uint256 maxIterations) external returns (uint256 paid);

    function compactDebtQueue(address user, uint256 startId, uint256 maxMerges)
        external
        returns (uint256 count, uint256 amount, uint256 intoId);

    function compactDebtQueueRange(address user, uint256 fromId, uint256 intoId, uint256 maxMerges)
        external
        returns (uint256 count, uint256 amount, uint256 resultId);

    function compactAdjacentDebtQueue(address user, uint256 startId, uint256 maxMerges)
        external
        returns (uint256 count, uint256 amount, uint256 intoId);

    function compactAdjacentDebtQueueRange(address user, uint256 fromId, uint256 toId, uint256 maxMerges)
        external
        returns (uint256 count, uint256 amount, uint256 intoId);

    function claimProtocolFees() external;

    function withdrawNative(address to, uint256 amount) external;

    function queueHarvestAvailable() external view returns (uint256);

    function lpBankrollAvailable() external view returns (uint256);

    function totalQueued() external view returns (uint256);

    function queueHead() external view returns (uint256);

    function queueNextId() external view returns (uint256);

    function userQueuedTotal(address user) external view returns (uint256);

    function userQueueHead(address user) external view returns (uint256);

    function userQueueTail(address user) external view returns (uint256);

    function queueNode(uint256 id) external view returns (address user, uint256 next, uint256 prev, uint256 amount);

    function positionOwner(uint256 positionId) external view returns (address);

    function getUserOpenPositionIds(address user) external view returns (uint256[] memory);

    function getMarketOi(uint32 instrumentId)
        external
        view
        returns (uint256 longSize, uint256 shortSize, uint256 longCap, uint256 shortCap, uint256 sizeScale);

    function liquidationPrice(uint256 positionId) external view returns (uint256);

    function previewPnl(uint256 positionId, uint256 markPrice) external view returns (int256 rawPnl, int256 pnl);

    function currentPrice(uint32 instrumentId) external view returns (uint256);

    function pythUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256);

    function setMaxPriceAge(uint256 maxPriceAge_) external;

    function setTradingPaused(bool paused) external;

    function setFeeRates(uint256 lossFeeRate_, uint256 winFeeRate_, uint256 liquidationFeeRate_) external;

    function setTradeMinimums(uint128 minCollateral, uint128 minNotional) external;

    function addInstrument(InstrumentLib.Config calldata config, uint64 sizeScale, string calldata symbol)
        external
        returns (uint32 instrumentId);

    function setInstrumentRisk(uint32 instrumentId, uint256 maxLeverage, uint256 maxNotional) external;

    function setInstrumentImpactConfig(
        uint32 instrumentId,
        uint256 impactC,
        uint256 impactB,
        uint256 impactA,
        uint256 profitHaircut
    ) external;

    function setMarketOiCaps(uint32 instrumentId, uint96 longCap, uint96 shortCap) external;
}
