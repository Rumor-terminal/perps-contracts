// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IExchange {
    struct Instrument {
        uint96 impactA;
        uint96 impactB;
        bytes32 priceId;
        uint32 maxLeverage;
        uint120 maxNotional;
        uint64 liquidationBuffer;
        uint64 profitHaircut;
        uint128 impactC;
    }

    struct MarketPause {
        bool paused;
        uint64 bid;
        uint64 ask;
        uint64 pausedAt;
    }

    struct MarketOi {
        uint96 longSize;
        uint96 shortSize;
        uint64 sizeScale;
        uint128 longCap;
        uint128 shortCap;
    }

    struct TradeMinimums {
        uint128 minCollateral;
        uint128 minNotional;
    }

    error UnsupportedCollateralDecimals();
    error FeeTooHigh();
    error InvalidInstrumentConfig();
    error InvalidSizeScale();
    error InvalidInstrumentId();
    error TradingPaused();
    error MarketIsPaused();
    error MarketAlreadyPaused();
    error UnpauseDisabled();
    error LeverageTooLow();
    error LeverageTooHigh();
    error TradeBelowMinimum();
    error NotionalBelowMinimum();
    error PositionTooLarge();
    error SizeOverflow();
    error OiCapExceeded();
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
    error InvalidPrice();

    event TradingPausedUpdated(bool paused);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event FeeRatesUpdated(
        uint256 lossFeeRate,
        uint256 winFeeRate,
        uint256 liquidationFeeRate
    );
    event TradeMinimumsUpdated(uint128 minCollateral, uint128 minNotional);
    event InstrumentAdded(
        uint32 indexed instrumentId,
        bytes32 priceId,
        string symbol
    );
    event InstrumentRiskUpdated(
        uint32 indexed instrumentId,
        uint32 maxLeverage,
        uint256 maxNotional
    );
    event InstrumentImpactConfigUpdated(
        uint32 indexed instrumentId,
        uint128 impactC,
        uint96 impactB,
        uint96 impactA,
        uint64 profitHaircut
    );
    event MarketOiCapsUpdated(
        uint32 indexed instrumentId,
        uint128 longCap,
        uint128 shortCap
    );
    event MarketPaused(
        uint32 indexed instrumentId,
        uint64 bid,
        uint64 ask,
        uint64 pausedAt
    );
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
        uint64 exitPrice,
        int256 rawPnl,
        int256 pnl,
        bool usedCredits,
        uint256 fees
    );
    event PositionsClosed(
        address indexed trader,
        uint256 credited,
        uint256 newBalance,
        uint256 fees
    );
    event Liquidated(
        uint256 indexed positionId,
        address indexed trader,
        uint64 price,
        uint64 liquidationPrice,
        bool usedCredits,
        uint256 fee
    );
    event LiquidationBatchProcessed(uint256 requested, uint256 liquidated);
    event SideBucketUpdated(uint256 sideBucket);
    event Claimed(address indexed user, uint256 amount);
    event HouseFunded(address indexed from, uint256 amount);
    event ProtocolFeesClaimed(
        address indexed recipient,
        uint256 amount,
        uint256 paid
    );

    function claim(uint256 amount) external;

    function fundHouse(uint256 amount) external;

    function openPosition(
        uint32 instrumentId,
        bool isLong,
        uint128 collateral,
        uint32 leverage,
        bytes[] calldata priceUpdate
    ) external payable returns (uint256 positionId);

    function closePositions(
        uint256[] calldata positionIds,
        bytes[] calldata priceUpdate
    ) external payable;

    function liquidate(
        uint256 positionId,
        bytes[] calldata priceUpdate
    ) external payable;

    function liquidateBatch(
        uint256[] calldata positionIds,
        bytes[] calldata priceUpdate
    ) external payable returns (uint256 liquidated);

    function harvest(uint256 maxIterations) external returns (uint256 paid);

    function compactDebtQueue(
        address user,
        uint256 startId,
        uint256 maxMerges
    ) external returns (uint256 count, uint256 amount, uint256 intoId);

    function compactDebtQueueRange(
        address user,
        uint256 fromId,
        uint256 intoId,
        uint256 maxMerges
    ) external returns (uint256 count, uint256 amount, uint256 resultId);

    function compactAdjacentDebtQueue(
        address user,
        uint256 startId,
        uint256 maxMerges
    ) external returns (uint256 count, uint256 amount, uint256 intoId);

    function compactAdjacentDebtQueueRange(
        address user,
        uint256 fromId,
        uint256 toId,
        uint256 maxMerges
    ) external returns (uint256 count, uint256 amount, uint256 intoId);

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

    function queueNode(
        uint256 id
    )
        external
        view
        returns (address user, uint48 next, uint48 prev, uint256 amount);

    function positionOwner(uint256 positionId) external view returns (address);

    function getUserOpenPositionIds(
        address user
    ) external view returns (uint256[] memory);

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
        );

    function liquidationPrice(
        uint256 positionId
    ) external view returns (uint64);

    function previewLiquidationPrice(
        uint32 instrumentId,
        uint64 entryPrice,
        uint32 leverage,
        bool isLong
    ) external view returns (uint64);

    function previewPnl(
        uint256 positionId,
        uint64 markPrice
    ) external view returns (int256 rawPnl, int256 pnl);

    function currentPrice(uint32 instrumentId) external view returns (uint64);

    function pythUpdateFee(
        bytes[] calldata priceUpdate
    ) external view returns (uint256);

    function setMaxPriceAge(uint256 maxPriceAge_) external;

    function setTradingPaused(bool paused) external;

    function setFeeRates(
        uint256 lossFeeRate_,
        uint256 winFeeRate_,
        uint256 liquidationFeeRate_
    ) external;

    function setTradeMinimums(
        uint128 minCollateral,
        uint128 minNotional
    ) external;

    function addInstrument(
        Instrument calldata config,
        uint64 sizeScale,
        string calldata symbol
    ) external returns (uint32 instrumentId);

    function setInstrumentRisk(
        uint32 instrumentId,
        uint32 maxLeverage,
        uint256 maxNotional
    ) external;

    function setInstrumentImpactConfig(
        uint32 instrumentId,
        uint128 impactC,
        uint96 impactB,
        uint96 impactA,
        uint64 profitHaircut
    ) external;

    function setMarketOiCaps(
        uint32 instrumentId,
        uint128 longCap,
        uint128 shortCap
    ) external;

    function pauseMarket(
        uint32 instrumentId,
        bytes[] calldata priceUpdate
    ) external payable;

    function unpauseMarket(uint32) external pure;
}
