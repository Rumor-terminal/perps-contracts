// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PerpsTest} from "./utils/PerpsTest.sol";
import {Martingaler} from "../src/Martingaler.sol";

contract PoolQueueTest is PerpsTest {
    function test_PoolStartsAtZero() public view {
        assertEq(pool(), 0);
        assertEq(perps.queueLength(), 0);
        assertEq(perps.poolDebt(), 0);
    }

    function test_NobodyCanPutMoneyIntoThePool() public {
        vm.prank(bob);
        usdt.transfer(address(perps), 1_000e6);

        assertEq(pool(), 0);
        uint256 owed = winBtc(alice);
        assertEq(queued(alice), owed);
    }

    function test_LossesGrowThePool() public {
        lose(100e18);
        lose(carol, 50e18);

        assertEq(pool(), 147e18);
    }

    function test_WinWithAnEmptyPoolReturnsWalletMarginAndQueuesTheProfit() public {
        uint256 before = wallet(alice);
        uint256 owed = winBtc(alice);

        assertEq(wallet(alice), before);
        assertEq(queued(alice), owed);
        assertEq(perps.poolDebt(), owed);
        assertEq(perps.queueLength(), 1);
        (address user, uint256 amount) = perps.queue(0);
        assertEq(user, alice);
        assertEq(amount, owed);
    }

    function test_PoolPaysWhatItCanAndQueuesTheRest() public {
        lose(50e18);
        uint256 before = wallet(alice);
        uint256 owed = winBtc(alice);

        assertEq(wallet(alice) - before, 49e18);
        assertEq(queued(alice), owed - 49e18);
        assertEq(pool(), 0);
    }

    function test_WinIsPaidInFullWhenPoolCanPayAndNobodyWaits() public {
        lose(1_000e18);
        uint256 before = wallet(alice);
        uint256 owed = winBtc(alice);

        assertEq(wallet(alice) - before, owed / SCALE * SCALE);
        assertEq(queued(alice), 0);
        assertEq(perps.queueLength(), 0);
        assertApproxEqAbs(pool(), 980e18 - owed - owed * 2 / 98, 2 * SCALE);
    }

    function test_NewWinnerJoinsTheBackEvenWhenPoolHasMoney() public {
        winBtc(alice);
        lose(1_000e18);
        uint256 before = wallet(bob);

        uint256 owed = winBtc(bob);

        assertEq(wallet(bob), before);
        assertEq(queued(bob), owed);
        assertEq(perps.queueLength(), 2);
        (address back,) = perps.queue(1);
        assertEq(back, bob);
        assertEq(pool(), 1_000e18);
    }

    function test_DocsExample() public {
        uint256 owed = winBtc(alice);
        uint256 start = wallet(alice);

        lose(bob, 60e18);
        perps.harvest(10);

        assertEq(wallet(alice) - start, 60e18);
        assertEq(queued(alice), owed - 60e18);
        assertEq(perps.queueLength(), 1);

        uint256 rest = owed - 60e18;
        lose(carol, (rest + SCALE - 1) / SCALE * SCALE + 10e18);
        perps.harvest(10);

        assertEq(perps.queueLength(), 0);
        assertEq(queued(alice), 0);
        assertApproxEqAbs(wallet(alice) - start, owed, SCALE);
        assertApproxEqAbs(pool(), 10e18, SCALE);
    }

    function test_PartialPaymentKeepsTheTraderFirstInLine() public {
        uint256 owedA = winBtc(alice);
        uint256 owedB = winBtc(bob);

        lose(50e18);
        assertEq(perps.harvest(10), 0);

        assertEq(queued(alice), owedA - 50e18);
        assertEq(queued(bob), owedB);
        (address front, uint256 amount) = perps.queue(perps.queueHead());
        assertEq(front, alice);
        assertEq(amount, owedA - 50e18);

        lose(1_000e18);
        assertEq(perps.harvest(10), 2);

        assertEq(queued(alice), 0);
        assertEq(queued(bob), 0);
        assertEq(perps.poolDebt(), 0);
    }

    function test_HarvestPaysFromTheFrontOnly() public {
        uint256 owedA = winBtc(alice);
        winBtc(bob);
        uint256 bobBefore = wallet(bob);

        lose((owedA + SCALE - 1) / SCALE * SCALE);
        assertEq(perps.harvest(1), 1);

        assertEq(queued(alice), 0);
        assertEq(wallet(bob), bobBefore);
        assertEq(perps.queueLength(), 1);
    }

    function test_HarvestWithAnEmptyPoolPaysNothing() public {
        uint256 owed = winBtc(alice);

        assertEq(perps.harvest(10), 0);

        assertEq(queued(alice), owed);
        assertEq(perps.queueLength(), 1);
    }

    function test_QueuedPayoutNeverShrinksOrExpires() public {
        uint256 owed = winBtc(alice);
        skip(365 days);
        assertEq(queued(alice), owed);

        lose(1_000e18);
        uint256 before = wallet(alice);
        perps.harvest(10);

        assertEq(wallet(alice) - before, owed / SCALE * SCALE);
    }

    function test_MarginComesFromQueuedFirst() public {
        uint256 owed = winBtc(alice);
        uint256 before = wallet(alice);

        vm.expectEmit(address(perps));
        emit Martingaler.Debited(alice, 100e18);
        uint256 id = open(alice, BTC, true, 100e18, 10);

        assertEq(wallet(alice), before);
        assertEq(queued(alice), owed - 100e18);
        assertEq(perps.poolDebt(), owed - 100e18);
        assertEq(position(id).debited, 100e18);
        assertEq(perps.totalLockedMargin(), 0);
    }

    function test_MarginComesFromTheWalletOnceQueuedRunsOut() public {
        uint256 owed = winBtc(alice);
        uint256 fromQueue = owed / SCALE * SCALE;
        uint256 before = wallet(alice);

        uint256 id = open(alice, BTC, true, 300e18, 10);

        assertEq(position(id).debited, fromQueue);
        assertEq(before - wallet(alice), 300e18 - fromQueue);
        assertEq(queued(alice), owed - fromQueue);
        assertEq(perps.totalLockedMargin(), 300e18 - fromQueue);
    }

    function test_LossOnQueuedMarginReducesWhatThePoolOwes() public {
        uint256 owed = winBtc(alice);
        uint256 id = open(alice, BTC, true, 100e18, 10);
        setPrice(BTC, movedPrice(BTC_PRICE, -300));
        uint256 before = wallet(alice);

        close(alice, id);

        assertEq(wallet(alice), before);
        assertEq(pool(), 0);
        assertEq(queued(alice), owed - 30e18);

        lose(1_000e18);
        perps.harvest(10);

        assertApproxEqAbs(wallet(alice) - before, owed - 30e18, SCALE);
        assertEq(queued(alice), 0);
        assertEq(perps.queueLength(), 0);
    }

    function test_WinOnQueuedMarginJoinsTheBackOfTheQueue() public {
        uint256 owed = winBtc(alice);
        winBtc(bob);
        uint256 id = open(alice, BTC, true, 100e18, 100);
        uint256 mark = movedPrice(BTC_PRICE, 200);
        setPrice(BTC, mark);
        uint256 net = netProfit(id, mark);
        uint256 before = wallet(alice);

        close(alice, id);

        assertEq(wallet(alice), before);
        assertEq(queued(alice), owed + net);
        assertEq(perps.queueLength(), 3);
        (address back, uint256 amount) = perps.queue(2);
        assertEq(back, alice);
        assertEq(amount, 100e18 + net);
    }

    function test_WalletPartOfMixedMarginNeverWaits() public {
        uint256 owed = winBtc(alice);
        uint256 id = open(alice, BTC, true, 300e18, 10);
        uint256 fromQueue = position(id).debited;
        setPrice(BTC, movedPrice(BTC_PRICE, -100));
        uint256 before = wallet(alice);

        close(alice, id);

        assertEq(wallet(alice) - before, 300e18 - fromQueue);
        assertEq(queued(alice), owed - 30e18);
    }

    function test_CloseAllLetsLossesPayWinsInTheSameBatch() public {
        uint256 longId = open(alice, BTC, true, 100e18, 10);
        uint256 shortId = open(alice, BTC, false, 100e18, 10);
        uint256 mark = movedPrice(BTC_PRICE, 300);
        setPrice(BTC, mark);
        uint256 net = netProfit(longId, mark);
        uint256 before = wallet(alice);

        closeAll(alice, list(longId, shortId));

        assertLt(net, 30e18);
        assertEq(perps.queueLength(), 0);
        assertEq(queued(alice), 0);
        assertApproxEqAbs(wallet(alice) - before, 170e18 + net, SCALE);
        assertApproxEqAbs(pool(), 29.4e18 - net - net * 2 / 98, 2 * SCALE);
    }
}
