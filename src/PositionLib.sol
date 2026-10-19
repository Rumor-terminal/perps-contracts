// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IExchange} from "./interfaces/IExchange.sol";
import {QueueLib} from "./QueueLib.sol";

library PositionLib {
    uint256 internal constant WAD = 1e18;

    struct Position {
        address owner;
        uint32 instrumentId;
        uint64 entryPrice;
        uint128 collateral;
        uint32 leverage;
        uint64 openedAt;
        bool isLong;
        bool usedCredits;
        bool isOpen;
    }

    function notional(Position storage p) internal view returns (uint256) {
        return uint256(p.collateral) * p.leverage;
    }

    function size(
        Position storage p,
        uint64 sizeScale
    ) internal view returns (uint96) {
        return sizeOf(notional(p), sizeScale, p.entryPrice);
    }

    function liquidationPrice(
        Position storage p,
        uint64 buffer
    ) internal view returns (uint64) {
        return liquidationPriceOf(p.entryPrice, p.leverage, buffer, p.isLong);
    }

    function isLiquidatable(
        Position storage p,
        uint64 price,
        uint64 buffer
    ) internal view returns (bool liquidatable, uint64 liqPrice) {
        liqPrice = liquidationPrice(p, buffer);
        liquidatable = p.isLong ? price <= liqPrice : price >= liqPrice;
    }

    function pnl(
        Position storage p,
        uint64 markPrice,
        IExchange.Instrument storage inst
    ) internal view returns (int256 rawPnl, int256 netPnl) {
        return
            QueueLib.computePositionPnl(
                p.entryPrice,
                markPrice,
                p.collateral,
                p.leverage,
                p.isLong,
                inst.profitHaircut,
                inst.impactA,
                inst.impactB,
                inst.impactC
            );
    }

    function sizeOf(
        uint256 notionalValue,
        uint64 sizeScale,
        uint64 price
    ) internal pure returns (uint96) {
        if (sizeScale == 0) revert IExchange.InvalidSizeScale();
        uint256 value = (notionalValue * sizeScale) / price;
        if (value > type(uint96).max) revert IExchange.SizeOverflow();
        return uint96(value);
    }

    function liquidationPriceOf(
        uint64 entryPrice,
        uint32 leverage,
        uint64 buffer,
        bool isLong
    ) internal pure returns (uint64) {
        uint256 step = entryPrice / leverage;
        if (isLong) {
            uint256 base = entryPrice - step;
            return uint64(base + (base * buffer) / WAD);
        }
        uint256 shortBase = entryPrice + step;
        return uint64(shortBase - (shortBase * buffer) / WAD);
    }
}
