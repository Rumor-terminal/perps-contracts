// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PerpsTest} from "./utils/PerpsTest.sol";
import {IPerpetualFutures} from "../src/interfaces/IPerpetualFutures.sol";

contract LiquidationTest is PerpsTest {
    function test_LiquidationPriceExample() public {
        uint256 longId = open(alice, BTC, true, 100e18, 100);
        uint256 shortId = open(alice, BTC, false, 100e18, 100);

        assertEq(perps.liquidationPrice(longId), 99_049.5e8);
        assertEq(perps.liquidationPrice(shortId), 100_949.5e8);
    }

    function test_BufferIsTheSameShareOfPriceAtAnyLeverage() public {
        uint32[4] memory leverages = [uint32(10), 100, 500, 1000];
        uint64[4] memory liquidatedAfter = [uint64(0.0995e18), 0.0095e18, 0.0015e18, 0.0005e18];

        for (uint256 i; i < leverages.length; ++i) {
            uint256 id = open(alice, BTC, true, 100e18, leverages[i]);
            uint256 liq = perps.liquidationPrice(id);
            uint256 marginRunsOut = BTC_PRICE - BTC_PRICE / leverages[i];

            assertEq(liq - marginRunsOut, marginRunsOut * 5 / 10_000);
            assertApproxEqAbs((BTC_PRICE - liq) * 1e18 / BTC_PRICE, liquidatedAfter[i], 0.00006e18);
        }
    }

    function test_LongIsLiquidatedOnlyOnceThePriceReachesItsLiquidationPrice() public {
        uint256 id = open(alice, BTC, true, 100e18, 100);
        uint256 liq = perps.liquidationPrice(id);

        setPrice(BTC, liq + 1);
        liquidate(id);
        assertTrue(position(id).isOpen);

        setPrice(BTC, liq);
        liquidate(id);
        assertFalse(position(id).isOpen);
    }

    function test_ShortIsLiquidatedOnlyOnceThePriceReachesItsLiquidationPrice() public {
        uint256 id = open(alice, BTC, false, 100e18, 100);
        uint256 liq = perps.liquidationPrice(id);

        setPrice(BTC, liq - 1);
        liquidate(id);
        assertTrue(position(id).isOpen);

        setPrice(BTC, liq);
        liquidate(id);
        assertFalse(position(id).isOpen);
    }

    function test_LiquidationTakesTheFullMargin() public {
        uint256 id = open(alice, BTC, true, 100e18, 100);
        uint256 liq = perps.liquidationPrice(id);
        setPrice(BTC, liq);
        uint256 before = wallet(alice);

        vm.expectEmit(address(perps));
        emit IPerpetualFutures.Liquidated(id, alice, liq, liq, 2e18, 10_000e18, 100e18);
        liquidate(id);

        assertEq(wallet(alice), before);
        assertEq(pool(), 98e18);
        assertEq(perps.totalLockedMargin(), 0);
        assertEq(perps.openPositionIds(alice).length, 0);
    }

    function test_LiquidationSends98PercentToPoolAnd2PercentToTreasury() public {
        uint256 id = open(alice, BTC, true, 100e18, 100);
        setPrice(BTC, perps.liquidationPrice(id));
        liquidate(id);

        assertEq(pool(), 98e18);
        assertEq(wallet(owner), 2e18);
    }

    function test_FastMovePastTheLiquidationPriceStillLosesOnlyTheMargin() public {
        uint256 liquidated = open(alice, BTC, true, 100e18, 100);
        uint256 closed = open(bob, BTC, true, 100e18, 100);
        setPrice(BTC, movedPrice(BTC_PRICE, -5_000));
        uint256 aliceBefore = wallet(alice);
        uint256 bobBefore = wallet(bob);

        liquidate(liquidated);
        close(bob, closed);

        assertEq(wallet(alice), aliceBefore);
        assertEq(wallet(bob), bobBefore);
        assertEq(pool(), 196e18);
    }

    function test_LiquidationDoesNotTouchOtherPositions() public {
        uint256 risky = open(alice, BTC, true, 100e18, 1000);
        uint256 safe = open(alice, BTC, false, 200e18, 10);
        setPrice(BTC, perps.liquidationPrice(risky));
        uint256 before = wallet(alice);

        liquidate(risky);

        assertEq(wallet(alice), before);
        assertTrue(position(safe).isOpen);
        assertEq(perps.totalLockedMargin(), 200e18);
        uint256[] memory ids = perps.openPositionIds(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], safe);
    }

    function test_BatchLiquidatesOnlyPositionsThatReachedTheirPrice() public {
        uint256 healthy = open(alice, BTC, true, 100e18, 10);
        uint256 risky = open(bob, BTC, true, 100e18, 1000);
        uint256 closed = open(carol, BTC, true, 100e18, 1000);
        close(carol, closed);
        setPrice(BTC, perps.liquidationPrice(risky));

        uint256[] memory ids = new uint256[](4);
        ids[0] = healthy;
        ids[1] = risky;
        ids[2] = closed;
        ids[3] = 999;
        liquidateAll(ids);

        assertTrue(position(healthy).isOpen);
        assertFalse(position(risky).isOpen);
        assertEq(pool(), 98e18);
    }

    function test_LiquidationCreditsShardsOnTheFullMargin() public {
        uint256 id = open(alice, BTC, true, 100e18, 1000);
        setPrice(BTC, perps.liquidationPrice(id));
        liquidate(id);

        assertEq(perps.totalLosses(), 100e18);
        assertEq(perps.shardsOf(alice), 10_000e18);
        assertEq(perps.totalShards(), 10_000e18);
    }
}
