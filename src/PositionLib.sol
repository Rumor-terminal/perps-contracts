// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IExchange} from "./interfaces/IExchange.sol";
import {QueueLib} from "./QueueLib.sol";
import {InstrumentLib} from "./InstrumentLib.sol";

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

library PositionLib {
    uint256 internal constant WAD = 1e18;

    function size(Position memory p, uint64 sizeScale) internal pure returns (uint96) {
        if (sizeScale == 0) revert InstrumentLib.InvalidSizeScale();
        uint256 value = (uint256(p.collateral) * p.leverage * sizeScale) / p.entryPrice;
        if (value > type(uint96).max) revert IExchange.SizeOverflow();
        return uint96(value);
    }

    function liquidationPrice(Position memory p, uint64 buffer) internal pure returns (uint64) {
        uint256 step = uint256(p.entryPrice) / p.leverage;
        if (p.isLong) {
            uint256 base = p.entryPrice - step;
            return uint64(base + (base * buffer) / WAD);
        }
        uint256 shortBase = p.entryPrice + step;
        return uint64(shortBase - (shortBase * buffer) / WAD);
    }

    function isLiquidatable(Position memory p, uint64 price, uint64 buffer)
        internal
        pure
        returns (bool liquidatable, uint64 liqPrice)
    {
        liqPrice = liquidationPrice(p, buffer);
        liquidatable = p.isLong ? price <= liqPrice : price >= liqPrice;
    }

    function pnl(Position memory p, uint64 markPrice, InstrumentLib.Config storage inst)
        internal
        view
        returns (int256 rawPnl, int256 netPnl)
    {
        return QueueLib.computePositionPnl(
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
}
