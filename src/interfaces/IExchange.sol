// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Config} from "../InstrumentLib.sol";

interface IExchange {
    error UnsupportedCollateralDecimals();
    error TradingPaused();
    error NothingToClose();
    error CollateralPrecision();
    error ZeroAmount();
    error InsufficientUpdateFee();

    event TradingPausedUpdated(bool paused);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event FeeRatesUpdated(uint256 lossFeeRate, uint256 winFeeRate, uint256 liquidationFeeRate);
    event TradeMinimumsUpdated(uint256 minCollateral, uint256 minNotional);
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
        uint64 entryPrice,
        uint128 collateral,
        uint32 leverage
    );
    event PositionClosed(
        uint256 indexed positionId, address indexed trader, uint256 exitPrice, int256 rawPnl, int256 pnl, uint256 fees
    );
    event PositionsClosed(address indexed trader, uint256 paid, uint256 queued, uint256 fees);
    event Liquidated(
        uint256 indexed positionId, address indexed trader, uint256 price, uint256 liquidationPrice, uint256 fee
    );
    event HouseFunded(address indexed from, uint256 amount);
    event ProtocolFeesClaimed(address indexed recipient, uint256 amount, uint256 paid);

    function fundHouse(uint256 amount) external;

    function openPosition(
        uint32 instrumentId,
        bool isLong,
        uint128 collateral,
        uint32 leverage,
        bytes[] calldata priceUpdate
    ) external payable returns (uint256 positionId);

    function closePositions(uint256[] calldata positionIds, bytes[] calldata priceUpdate) external payable;

    function liquidateBatch(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        returns (uint256 liquidated);

    function claimProtocolFees() external;

    function withdrawNative(address to, uint256 amount) external;

    function getUserOpenPositionIds(address user) external view returns (uint256[] memory);

    function liquidationPrice(uint256 positionId) external view returns (uint256);

    function previewPnl(uint256 positionId, uint256 markPrice) external view returns (int256 rawPnl, int256 pnl);

    function pythUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256);

    function setMaxPriceAge(uint256 maxPriceAge_) external;

    function setTradingPaused(bool paused) external;

    function setFeeRates(uint256 lossFeeRate_, uint256 winFeeRate_, uint256 liquidationFeeRate_) external;

    function setTradeMinimums(uint256 minCollateral, uint256 minNotional) external;

    function addInstrument(Config calldata config, uint64 sizeScale, string calldata symbol)
        external
        returns (uint32 instrumentId);

    function setRiskParams(uint32 instrumentId, uint256 maxLeverage, uint256 maxNotional) external;

    function setImpactConfig(
        uint32 instrumentId,
        uint256 impactC,
        uint256 impactB,
        uint256 impactA,
        uint256 profitHaircut
    ) external;

    function setOiCaps(uint32 instrumentId, uint96 longCap, uint96 shortCap) external;
}
