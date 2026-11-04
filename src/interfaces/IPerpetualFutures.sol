// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {Config} from "../InstrumentLib.sol";

struct OpenRequest {
    address trader;
    uint32 instrumentId;
    bool isLong;
    uint128 collateral;
    uint32 leverage;
    uint256 nonce;
    uint256 deadline;
    address ref;
}

struct CloseRequest {
    address trader;
    uint256[] positionIds;
    uint256 nonce;
    uint256 deadline;
}

interface IPerpetualFutures {
    error InsufficientUpdateFee();
    error NotExecutor();
    error SignatureExpired();
    error InvalidSignature();

    event ExecutorUpdated(address indexed executor, bool allowed);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event FeeRatesUpdated(uint256 lossFeeRate, uint256 winFeeRate, uint256 liquidationFeeRate);
    event TradeMinimumsUpdated(uint256 minCollateral, uint256 minNotional);
    event InstrumentAdded(uint32 indexed instrumentId, bytes32 priceId, string symbol);
    event InstrumentLiquidationBufferUpdated(uint32 indexed instrumentId, uint256 liquidationBuffer);
    event InstrumentHaircutConfigUpdated(
        uint32 indexed instrumentId,
        uint256 moveScale,
        uint256 referenceSize,
        uint256 marketFactor,
        uint256 profitHaircut
    );
    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        uint32 instrumentId,
        bool isLong,
        uint64 entryPrice,
        uint128 collateral,
        uint32 leverage
    );
    event PositionClosed(
        uint256 indexed positionId,
        address indexed trader,
        uint256 markPrice,
        int256 rawPnl,
        int256 pnl,
        uint256 fees,
        uint256 shards,
        uint256 shardsRate
    );
    event ReferrerSet(address indexed trader, address indexed referrer);
    event ReferralShardsCredited(address indexed referrer, address indexed trader, uint256 shards);
    event Liquidated(
        uint256 indexed positionId,
        address indexed trader,
        uint256 price,
        uint256 liquidationPrice,
        uint256 fee,
        uint256 shards,
        uint256 shardsRate
    );

    function openPosition(OpenRequest calldata request, bytes calldata signature, bytes[] calldata priceUpdate)
        external
        payable
        returns (uint256 positionId);

    function closePositions(uint256[] calldata positionIds, bytes[] calldata priceUpdate) external payable;

    function closePositionsWithSig(
        CloseRequest calldata request,
        bytes calldata signature,
        bytes[] calldata priceUpdate
    ) external payable;

    function liquidateBatch(uint256[] calldata positionIds, bytes[] calldata priceUpdate) external payable;

    function withdrawNative(address to, uint256 amount) external;

    function pyth() external view returns (IPyth);

    function isExecutor(address executor) external view returns (bool);

    function openPositionIds(address trader) external view returns (uint256[] memory);

    function liquidationPrice(uint256 positionId) external view returns (uint256);

    function previewPnl(uint256 positionId, uint256 markPrice) external view returns (int256 rawPnl, int256 pnl);

    function getShardsRate() external view returns (uint256);

    function referrerOf(address trader) external view returns (address);

    function hasTraded(address trader) external view returns (bool);

    function pythUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256);

    function setMaxPriceAge(uint256 maxPriceAge_) external;

    function setExecutor(address executor, bool allowed) external;

    function setFeeRates(uint256 lossFeeRate_, uint256 winFeeRate_, uint256 liquidationFeeRate_) external;

    function setTradeMinimums(uint256 minCollateral_, uint256 minNotional_) external;

    function addInstrument(Config calldata config, string calldata symbol) external returns (uint32 instrumentId);

    function setLiquidationBuffer(uint32 instrumentId, uint256 liquidationBuffer) external;

    function setHaircutConfig(
        uint32 instrumentId,
        uint256 moveScale,
        uint256 referenceSize,
        uint256 marketFactor,
        uint256 profitHaircut
    ) external;
}
