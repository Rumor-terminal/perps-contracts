// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Config} from "../InstrumentLib.sol";

struct OpenRequest {
    address trader;
    uint32 instrumentId;
    bool isLong;
    uint128 collateral;
    uint32 leverage;
    uint256 nonce;
    uint256 deadline;
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
    event InstrumentRiskUpdated(
        uint32 indexed instrumentId, uint256 maxLeverage, uint256 maxNotional, uint256 liquidationBuffer
    );
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
        uint256 indexed positionId, address indexed trader, uint256 markPrice, int256 rawPnl, int256 pnl, uint256 fees
    );
    event Liquidated(
        uint256 indexed positionId, address indexed trader, uint256 price, uint256 liquidationPrice, uint256 fee
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

    function openPositionIds(address trader) external view returns (uint256[] memory);

    function liquidationPrice(uint256 positionId) external view returns (uint256);

    function previewPnl(uint256 positionId, uint256 markPrice) external view returns (int256 rawPnl, int256 pnl);

    function pythUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256);

    function setMaxPriceAge(uint256 maxPriceAge_) external;

    function setExecutor(address executor, bool allowed) external;

    function setFeeRates(uint256 lossFeeRate_, uint256 winFeeRate_, uint256 liquidationFeeRate_) external;

    function setTradeMinimums(uint256 minCollateral_, uint256 minNotional_) external;

    function addInstrument(Config calldata config, string calldata symbol) external returns (uint32 instrumentId);

    function setRiskParams(uint32 instrumentId, uint256 maxLeverage, uint256 maxNotional, uint256 liquidationBuffer)
        external;

    function setHaircutConfig(
        uint32 instrumentId,
        uint256 moveScale,
        uint256 referenceSize,
        uint256 marketFactor,
        uint256 profitHaircut
    ) external;

}
