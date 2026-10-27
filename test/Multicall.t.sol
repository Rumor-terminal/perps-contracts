// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PerpsTest} from "./utils/PerpsTest.sol";
import {MulticallExecutor} from "../src/MulticallExecutor.sol";
import {OpenRequest, CloseRequest} from "../src/interfaces/IPerpetualFutures.sol";

contract MulticallTest is PerpsTest {
    MulticallExecutor internal multicall;

    function setUp() public override {
        super.setUp();
        multicall = new MulticallExecutor(perps);
        vm.prank(owner);
        perps.setExecutor(address(multicall), true);
        vm.deal(executor, 1 ether);
    }

    function signedOpens(address[] memory traders)
        internal
        returns (OpenRequest[] memory requests, bytes[] memory signatures)
    {
        requests = new OpenRequest[](traders.length);
        signatures = new bytes[](traders.length);
        for (uint256 i; i < traders.length; ++i) {
            requests[i] = openRequest(traders[i], BTC, true, 100e18, 10);
            signatures[i] = sign(perps, keyOf[traders[i]], requests[i]);
        }
    }

    function signedClose(address trader, uint256 id)
        internal
        returns (CloseRequest[] memory requests, bytes[] memory signatures)
    {
        requests = new CloseRequest[](1);
        signatures = new bytes[](1);
        requests[0] = closeRequest(trader, list(id));
        signatures[0] = sign(perps, keyOf[trader], requests[0]);
    }

    function three(address a, address b, address c) internal pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = a;
        t[1] = b;
        t[2] = c;
    }

    function test_OnlyExchangeExecutorCalls() public {
        (OpenRequest[] memory opens, bytes[] memory sigs) = signedOpens(three(alice, bob, carol));
        CloseRequest[] memory closes;
        bytes[] memory closeSigs;

        vm.expectRevert();
        vm.prank(alice);
        multicall.execute(opens, sigs, closes, closeSigs, new bytes[](0));

        vm.expectRevert();
        vm.prank(keeper);
        multicall.execute(opens, sigs, closes, closeSigs, new bytes[](0));
    }

    function test_OpensAndClosesManyWithOnePriceUpdate() public {
        uint256 toClose = open(loser, ETH, false, 100e18, 10);
        skip(MAX_PRICE_AGE + 1);
        (OpenRequest[] memory opens, bytes[] memory sigs) = signedOpens(three(alice, bob, carol));
        (CloseRequest[] memory closes, bytes[] memory closeSigs) = signedClose(loser, toClose);

        uint256 price = movedPrice(BTC_PRICE, 100);
        bytes[] memory update = new bytes[](2);
        update[0] = priceUpdate(BTC, int64(uint64(price)), -8)[0];
        update[1] = priceUpdate(ETH, int64(uint64(ETH_PRICE)), -8)[0];
        uint256 fee = perps.pythUpdateFee(update);
        uint256 first = perps.nextPositionId();

        vm.prank(executor);
        multicall.execute{value: fee}(opens, sigs, closes, closeSigs, update);

        for (uint256 i; i < 3; ++i) {
            assertTrue(position(first + i).isOpen);
            assertEq(position(first + i).entryPrice, price);
        }
        assertEq(position(first).trader, alice);
        assertEq(position(first + 1).trader, bob);
        assertEq(position(first + 2).trader, carol);
        assertFalse(position(toClose).isOpen);
        assertEq(address(multicall).balance, 0);
        assertEq(executor.balance, 1 ether - fee);
    }

    function test_StalePriceWithoutUpdateOpensNothing() public {
        (OpenRequest[] memory opens, bytes[] memory sigs) = signedOpens(three(alice, bob, carol));
        CloseRequest[] memory closes;
        bytes[] memory closeSigs;
        skip(MAX_PRICE_AGE + 1);

        vm.prank(executor);
        multicall.execute(opens, sigs, closes, closeSigs, new bytes[](0));

        assertEq(perps.openPositionIds(alice).length, 0);
        assertEq(perps.openPositionIds(bob).length, 0);
        assertEq(perps.openPositionIds(carol).length, 0);
    }

    function test_BadSignatureDoesNotBlockTheBatch() public {
        (OpenRequest[] memory opens, bytes[] memory sigs) = signedOpens(three(alice, bob, carol));
        sigs[1] = sign(perps, keyOf[alice], opens[1]);
        CloseRequest[] memory closes;
        bytes[] memory closeSigs;

        vm.prank(executor);
        multicall.execute(opens, sigs, closes, closeSigs, new bytes[](0));

        assertEq(perps.openPositionIds(alice).length, 1);
        assertEq(perps.openPositionIds(bob).length, 0);
        assertEq(perps.openPositionIds(carol).length, 1);
        assertEq(perps.nonces(bob), 0);
    }

    function test_CloseOnlyTouchesTheSignersPositions() public {
        uint256 own = open(alice, BTC, true, 100e18, 10);
        uint256 foreign = open(bob, BTC, true, 100e18, 10);
        OpenRequest[] memory opens;
        bytes[] memory sigs;
        CloseRequest[] memory closes = new CloseRequest[](1);
        bytes[] memory closeSigs = new bytes[](1);
        closes[0] = closeRequest(alice, list(own, foreign));
        closeSigs[0] = sign(perps, keyOf[alice], closes[0]);

        vm.prank(executor);
        multicall.execute(opens, sigs, closes, closeSigs, new bytes[](0));

        assertFalse(position(own).isOpen);
        assertTrue(position(foreign).isOpen);
    }

    function test_UnregisteredMulticallOpensNothing() public {
        vm.prank(owner);
        perps.setExecutor(address(multicall), false);
        (OpenRequest[] memory opens, bytes[] memory sigs) = signedOpens(three(alice, bob, carol));
        CloseRequest[] memory closes;
        bytes[] memory closeSigs;

        vm.prank(executor);
        multicall.execute(opens, sigs, closes, closeSigs, new bytes[](0));

        assertEq(perps.nextPositionId(), 0);
    }
}
