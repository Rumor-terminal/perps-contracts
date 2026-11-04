// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {PerpsTest} from "./utils/PerpsTest.sol";
import {IPerpetualFutures} from "../src/interfaces/IPerpetualFutures.sol";

contract ReferralsTest is PerpsTest {
    function openWithRef(address trader, address ref) internal returns (uint256) {
        return open(openRequest(trader, BNB, false, 100e18, 10, ref), new bytes[](0));
    }

    function loseWithRef(address trader, address ref) internal {
        uint256 price = currentPrice(BNB);
        uint256 id = openWithRef(trader, ref);
        setPrice(BNB, price * 11 / 10);
        close(trader, id);
        setPrice(BNB, price);
    }

    function test_FirstTradeBindsTheReferrer() public {
        vm.expectEmit(address(perps));
        emit IPerpetualFutures.ReferrerSet(alice, bob);
        openWithRef(alice, bob);

        assertEq(perps.referrerOf(alice), bob);
        assertTrue(perps.hasTraded(alice));
    }

    function test_ReferrerGetsFifteenPercentOnTop() public {
        loseWithRef(alice, bob);

        uint256 shards = perps.shardsOf(alice);
        assertGt(shards, 0);
        assertEq(perps.shardsOf(bob), shards * 15 / 100);
        assertEq(perps.totalShards(), shards + shards * 15 / 100);
    }

    function test_ReferralShardsAreEmittedForTheHistory() public {
        uint256 price = currentPrice(BNB);
        uint256 id = openWithRef(alice, bob);
        setPrice(BNB, price * 11 / 10);

        vm.recordLogs();
        close(alice, id);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IPerpetualFutures.ReferralShardsCredited.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), bob);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), alice);
            assertEq(abi.decode(logs[i].data, (uint256)), perps.shardsOf(bob));
        }
        assertTrue(found);
    }

    function test_LiquidationCreditsTheReferrerToo() public {
        uint256 price = currentPrice(BNB);
        uint256 id = openWithRef(alice, bob);
        setPrice(BNB, price * 2);

        liquidate(id);

        assertEq(perps.shardsOf(bob), perps.shardsOf(alice) * 15 / 100);
    }

    function test_ReferralsCostTheReferralNothing() public {
        lose(carol, 100e18);
        loseWithRef(alice, bob);

        assertEq(perps.shardsOf(alice), perps.shardsOf(carol));
    }

    function test_SelfReferralIsIgnored() public {
        openWithRef(alice, alice);

        assertEq(perps.referrerOf(alice), address(0));
    }

    function test_TraderWhoAlreadyTradedCannotBeReferred() public {
        open(alice, BNB, false, 100e18, 10);
        openWithRef(alice, bob);

        assertEq(perps.referrerOf(alice), address(0));
    }

    function test_SecondLinkDoesNotOverrideTheFirst() public {
        openWithRef(alice, bob);
        openWithRef(alice, carol);

        assertEq(perps.referrerOf(alice), bob);
    }

    function test_ReferrerCanBeAnyWalletEvenWithoutTrades() public {
        address stranger = makeAddr("stranger");
        loseWithRef(alice, stranger);

        assertGt(perps.shardsOf(stranger), 0);
    }
}
