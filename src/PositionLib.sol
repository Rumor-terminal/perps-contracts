// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Config, WAD} from "./InstrumentLib.sol";

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
    function notional(Position memory p) internal pure returns (uint256) {
        return uint256(p.collateral) * p.leverage;
    }

    function size(Position memory p, uint256 sizeScale) internal pure returns (uint256) {
        return notional(p) * sizeScale / p.entryPrice;
    }

    function liquidationPrice(Position memory p, uint256 buffer) internal pure returns (uint256) {
        uint256 step = uint256(p.entryPrice) / p.leverage;

        if (p.isLong) {
            uint256 base = p.entryPrice - step;
            return base + (base * buffer) / WAD;
        }

        uint256 shortBase = p.entryPrice + step;
        return shortBase - (shortBase * buffer) / WAD;
    }

    function isLiquidatable(Position memory p, uint256 price, uint256 buffer)
        internal
        pure
        returns (bool liquidatable, uint256 liqPrice)
    {
        liqPrice = liquidationPrice(p, buffer);
        liquidatable = p.isLong ? price <= liqPrice : price >= liqPrice;
    }

    function pnl(Position memory p, uint256 markPrice, Config storage instrument)
        internal
        view
        returns (int256 rawPnl, int256 netPnl)
    {
        uint256 entryPrice = p.entryPrice;
        uint256 exitPrice = _exitPrice(entryPrice, markPrice, p.isLong);
        int256 priceDelta = p.isLong ? int256(exitPrice) - int256(entryPrice) : int256(entryPrice) - int256(exitPrice);
        rawPnl = int256(notional(p)) * priceDelta / int256(entryPrice);

        if (rawPnl > 0) {
            netPnl = applyImpact(
                rawPnl,
                entryPrice,
                exitPrice,
                instrument.profitHaircut,
                instrument.impactA,
                instrument.impactB,
                instrument.impactC
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
        uint256 profitHaircut,
        uint256 impactA,
        uint256 impactB,
        uint256 impactC
    ) internal pure returns (int256) {
        uint256 move = exitPrice >= entryPrice ? exitPrice - entryPrice : entryPrice - exitPrice;
        uint256 denominator = _impactDenominator(move * WAD / entryPrice, impactA, impactB, impactC);
        if (denominator == 0) return 0;

        uint256 factor = (WAD - profitHaircut) * WAD / denominator;
        return profit * int256(factor) / int256(WAD);
    }

    function _exitPrice(uint256 entryPrice, uint256 markPrice, bool isLong) private pure returns (uint256) {
        uint256 tolerance = entryPrice / 50_000;

        if (isLong) {
            if (markPrice > entryPrice + tolerance) return markPrice - tolerance;
            return markPrice > entryPrice ? entryPrice : markPrice;
        }

        if (markPrice + tolerance < entryPrice) return markPrice + tolerance;
        return markPrice < entryPrice ? entryPrice : markPrice;
    }

    function _impactDenominator(uint256 moveWad, uint256 impactA, uint256 impactB, uint256 impactC)
        private
        pure
        returns (uint256)
    {
        uint256 a = moveWad * impactA / WAD;
        uint256 b = 1e6 * moveWad * impactB / WAD;
        if (a == 0 || b == 0) return 0;

        uint256 inverseB = impactC * WAD / b;
        if (inverseB > 1e36) return 0;

        return WAD + 1e36 / a + inverseB;
    }
}
