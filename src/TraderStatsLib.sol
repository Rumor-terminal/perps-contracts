// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

struct TraderStats {
    uint128 volume;
    uint128 profit;
    uint128 loss;
    uint128 liquidated;
    uint128 fees;
    uint32 positions;
    uint32 liquidations;
}

library TraderStatsLib {
    using SafeCast for uint256;

    function recordOpen(TraderStats storage s, uint256 notional) internal {
        s.volume += notional.toUint128();
        ++s.positions;
    }

    function recordClose(TraderStats storage s, int256 pnl, uint256 fee) internal {
        if (pnl > 0) s.profit += uint256(pnl).toUint128();
        else s.loss += uint256(-pnl).toUint128();
        s.fees += fee.toUint128();
    }

    function recordLiquidation(TraderStats storage s, uint256 collateral, uint256 fee) internal {
        s.liquidated += collateral.toUint128();
        s.fees += fee.toUint128();
        ++s.liquidations;
    }
}
