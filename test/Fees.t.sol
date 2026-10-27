// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PerpsTest} from "./utils/PerpsTest.sol";

contract FeesTest is PerpsTest {
    function test_LosingCloseSends98PercentToPoolAnd2PercentToTreasury() public {
        lose(100e18);

        assertEq(pool(), 98e18);
        assertEq(wallet(owner), 2e18);
    }

    function test_WinFeeIsTwoPercentOfWhatIsLeftAfterTheHaircut() public {
        lose(1_000e18);
        uint256 id = open(alice, BTC, true, 100e18, 100);
        uint256 mark = movedPrice(BTC_PRICE, 200);
        setPrice(BTC, mark);
        (int256 rawPnl, int256 pnl) = perps.previewPnl(id, mark);
        uint256 profit = uint256(pnl);

        close(alice, id);

        assertLt(profit, uint256(rawPnl));
        assertApproxEqAbs(wallet(owner), 20e18 + profit * 2 / 100, SCALE);
        assertApproxEqAbs(pool(), 980e18 - profit, 2 * SCALE);
    }

    function test_WinFeeStaysInThePoolWhenPoolCannotCoverIt() public {
        uint256 id = open(alice, BTC, true, 100e18, 100);
        uint256 mark = movedPrice(BTC_PRICE, 200);
        uint256 net = netProfit(id, mark);
        lose((net * 100 / 98 + SCALE) / SCALE * SCALE);
        uint256 ownerBefore = wallet(owner);
        setPrice(BTC, mark);
        uint256 before = wallet(alice);

        close(alice, id);

        assertApproxEqAbs(wallet(alice) - before, 100e18 + net, SCALE);
        assertEq(queued(alice), 0);
        assertEq(wallet(owner), ownerBefore);
    }

    function test_FeesAreSetAsideFromThePool() public {
        lose(100e18);
        uint256 before = wallet(alice);

        uint256 owed = winBtc(alice);

        assertEq(wallet(alice) - before, 98e18);
        assertEq(queued(alice), owed - 98e18);
        assertEq(wallet(owner), 2e18);
    }

    function test_WinFeeOnAProfitThatWaitsStaysInThePool() public {
        winBtc(alice);

        assertEq(wallet(owner), 0);
    }

    function test_WinFeeWhileQueueIsActiveStaysInThePool() public {
        winBtc(alice);
        lose(1_000e18);

        winBtc(bob);

        assertEq(wallet(owner), 0);
        assertEq(pool(), 1_000e18);
    }

    function test_LosingCloseWhileQueueIsActivePaysNoFee() public {
        uint256 owed = winBtc(alice);

        lose(100e18);
        perps.harvest(10);

        assertEq(wallet(owner), 0);
        assertEq(queued(alice), owed - 100e18);
    }

    function test_LiquidationWhileQueueIsActivePaysNoFee() public {
        winBtc(alice);
        uint256 id = open(bob, BTC, true, 100e18, 100);
        setPrice(BTC, perps.liquidationPrice(id));

        liquidate(id);

        assertEq(wallet(owner), 0);
        assertEq(pool(), 100e18);
    }
}
