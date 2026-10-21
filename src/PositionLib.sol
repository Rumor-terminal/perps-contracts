// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Config, InstrumentLib, WAD} from "./InstrumentLib.sol";

struct Position {
    address owner;
    uint32 instrumentId;
    uint64 entryPrice;
    uint128 collateral;
    uint128 debited;
    uint32 leverage;
    uint64 openedAt;
    bool isLong;
    bool isOpen;
}

library PositionLib {
    error ZeroLeverage();
    error CollateralBelowMinimum();
    error NotionalBelowMinimum();
    error CollateralPrecision();

    uint256 internal constant EXIT_SPREAD = 0.00002e18;

    function validate(Position memory p, uint256 minCollateral, uint256 minNotional, uint256 collateralScale)
        internal
        pure
    {
        if (p.leverage == 0) revert ZeroLeverage();
        if (p.collateral < minCollateral) revert CollateralBelowMinimum();
        if (notional(p) < minNotional) revert NotionalBelowMinimum();
        if (p.collateral % collateralScale != 0) revert CollateralPrecision();
    }

    function notional(Position memory p) internal pure returns (uint256) {
        return uint256(p.collateral) * p.leverage;
    }

    function size(Position memory p) internal pure returns (uint256) {
        return notional(p) * InstrumentLib.PRICE_SCALE / p.entryPrice;
    }

    function liquidationPrice(Position memory p, uint256 buffer) internal pure returns (uint256) {
        uint256 step = uint256(p.entryPrice) / p.leverage;
        uint256 base = p.isLong ? p.entryPrice - step : p.entryPrice + step;
        uint256 shift = base * buffer / WAD;
        return p.isLong ? base + shift : base - shift;
    }

    function isLiquidatable(Position memory p, uint256 price, uint256 buffer)
        internal
        pure
        returns (bool liquidatable, uint256 liqPrice)
    {
        liqPrice = liquidationPrice(p, buffer);
        liquidatable = p.isLong ? price <= liqPrice : price >= liqPrice;
    }

    function pnl(Position memory p, uint256 markPrice, Config storage config)
        internal
        view
        returns (int256 rawPnl, int256 netPnl)
    {
        uint256 entryPrice = p.entryPrice;
        uint256 exitPrice = _spreadAdjustedExitPrice(entryPrice, markPrice, p.isLong);
        int256 priceDelta = p.isLong ? int256(exitPrice) - int256(entryPrice) : int256(entryPrice) - int256(exitPrice);
        rawPnl = int256(notional(p)) * priceDelta / int256(entryPrice);

        if (rawPnl > 0) {
            netPnl = applyImpact(
                rawPnl, entryPrice, exitPrice, config.impactA, config.impactB, config.impactC, config.profitHaircut
            );
        } else {
            int256 maxLoss = -int256(uint256(p.collateral));
            netPnl = rawPnl < maxLoss ? maxLoss : rawPnl;
        }
    }

    function applyImpact(
        int256 profit,
        uint256 entryPrice,
        uint256 exitPrice,
        uint256 impactA,
        uint256 impactB,
        uint256 impactC,
        uint256 profitHaircut
    ) internal pure returns (int256) {
        uint256 move = exitPrice >= entryPrice ? exitPrice - entryPrice : entryPrice - exitPrice;
        uint256 denominator = _impactDenominator(move * WAD / entryPrice, impactA, impactB, impactC);
        if (denominator == 0) return 0;

        uint256 factor = (WAD - profitHaircut) * WAD / denominator;
        return profit * int256(factor) / int256(WAD);
    }

    function _spreadAdjustedExitPrice(uint256 entryPrice, uint256 markPrice, bool isLong)
        private
        pure
        returns (uint256)
    {
        uint256 spread = entryPrice * EXIT_SPREAD / WAD;
        if (isLong) return markPrice > entryPrice ? Math.max(markPrice - spread, entryPrice) : markPrice;
        return markPrice < entryPrice ? Math.min(markPrice + spread, entryPrice) : markPrice;
    }

    function _impactDenominator(uint256 moveWad, uint256 impactA, uint256 impactB, uint256 impactC)
        private
        pure
        returns (uint256)
    {
        uint256 a = moveWad * impactA / WAD;
        uint256 b = moveWad * impactB / WAD;
        if (a == 0 || b == 0) return 0;

        uint256 inverseB = impactC * WAD / b;
        if (inverseB > WAD * WAD) return 0;

        return WAD + WAD * WAD / a + inverseB;
    }
}
