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

    function size(
        Position storage p,
        uint64 sizeScale
    ) internal view returns (uint96) {
        return _size(p.collateral, p.leverage, p.entryPrice, sizeScale);
    }

    function sizeOf(
        Position memory p,
        uint64 sizeScale
    ) internal pure returns (uint96) {
        return _size(p.collateral, p.leverage, p.entryPrice, sizeScale);
    }

    function liquidationPrice(
        Position storage p,
        uint64 buffer
    ) internal view returns (uint64) {
        return _liquidationPrice(p.entryPrice, p.leverage, p.isLong, buffer);
    }

    function liquidationPriceOf(
        Position memory p,
        uint64 buffer
    ) internal pure returns (uint64) {
        return _liquidationPrice(p.entryPrice, p.leverage, p.isLong, buffer);
    }

    function isLiquidatable(
        Position storage p,
        uint64 price,
        uint64 buffer
    ) internal view returns (bool liquidatable, uint64 liqPrice) {
        liqPrice = liquidationPrice(p, buffer);
        liquidatable = _crossed(p.isLong, price, liqPrice);
    }

    function isLiquidatableOf(
        Position memory p,
        uint64 price,
        uint64 buffer
    ) internal pure returns (bool liquidatable, uint64 liqPrice) {
        liqPrice = liquidationPriceOf(p, buffer);
        liquidatable = _crossed(p.isLong, price, liqPrice);
    }

    function pnl(
        Position storage p,
        uint64 markPrice,
        IExchange.Instrument storage inst
    ) internal view returns (int256 rawPnl, int256 netPnl) {
        return
            _pnl(
                p.entryPrice,
                markPrice,
                p.collateral,
                p.leverage,
                p.isLong,
                inst
            );
    }

    function pnlOf(
        Position memory p,
        uint64 markPrice,
        IExchange.Instrument storage inst
    ) internal view returns (int256 rawPnl, int256 netPnl) {
        return
            _pnl(
                p.entryPrice,
                markPrice,
                p.collateral,
                p.leverage,
                p.isLong,
                inst
            );
    }

    function _size(
        uint128 collateral,
        uint32 leverage,
        uint64 entryPrice,
        uint64 sizeScale
    ) private pure returns (uint96) {
        if (sizeScale == 0) revert IExchange.InvalidSizeScale();
        uint256 value = (uint256(collateral) * leverage * sizeScale) /
            entryPrice;
        if (value > type(uint96).max) revert IExchange.SizeOverflow();
        return uint96(value);
    }

    function _liquidationPrice(
        uint64 entryPrice,
        uint32 leverage,
        bool isLong,
        uint64 buffer
    ) private pure returns (uint64) {
        uint256 step = uint256(entryPrice) / leverage;
        if (isLong) {
            uint256 base = entryPrice - step;
            return uint64(base + (base * buffer) / WAD);
        }
        uint256 shortBase = entryPrice + step;
        return uint64(shortBase - (shortBase * buffer) / WAD);
    }

    function _crossed(
        bool isLong,
        uint64 price,
        uint64 liqPrice
    ) private pure returns (bool) {
        return isLong ? price <= liqPrice : price >= liqPrice;
    }

    function _pnl(
        uint64 entryPrice,
        uint64 markPrice,
        uint128 collateral,
        uint32 leverage,
        bool isLong,
        IExchange.Instrument storage inst
    ) private view returns (int256 rawPnl, int256 netPnl) {
        return
            QueueLib.computePositionPnl(
                entryPrice,
                markPrice,
                collateral,
                leverage,
                isLong,
                inst.profitHaircut,
                inst.impactA,
                inst.impactB,
                inst.impactC
            );
    }
}
