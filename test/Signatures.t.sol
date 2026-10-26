// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {PerpsTest} from "./utils/PerpsTest.sol";
import {IPerpetualFutures, OpenRequest, CloseRequest} from "../src/interfaces/IPerpetualFutures.sol";

contract SignaturesTest is PerpsTest {
    function test_OnlyExecutorOpens() public {
        OpenRequest memory request = openRequest(alice, BTC, true, 100e18, 10);
        bytes memory signature = sign(perps, keyOf[alice], request);

        vm.expectRevert(IPerpetualFutures.NotExecutor.selector);
        vm.prank(alice);
        perps.openPosition(request, signature, new bytes[](0));

        vm.expectRevert(IPerpetualFutures.NotExecutor.selector);
        vm.prank(keeper);
        perps.openPosition(request, signature, new bytes[](0));
    }

    function test_OwnerAddsAndRemovesExecutors() public {
        vm.expectEmit(address(perps));
        emit IPerpetualFutures.ExecutorUpdated(keeper, true);
        vm.prank(owner);
        perps.setExecutor(keeper, true);
        assertTrue(perps.isExecutor(keeper));

        OpenRequest memory request = openRequest(alice, BTC, true, 100e18, 10);
        bytes memory signature = sign(perps, keyOf[alice], request);
        vm.prank(keeper);
        perps.openPosition(request, signature, new bytes[](0));

        vm.prank(owner);
        perps.setExecutor(keeper, false);
        request = openRequest(alice, BTC, true, 100e18, 10);
        signature = sign(perps, keyOf[alice], request);

        vm.expectRevert(IPerpetualFutures.NotExecutor.selector);
        vm.prank(keeper);
        perps.openPosition(request, signature, new bytes[](0));

        open(alice, BTC, true, 100e18, 10);
    }

    function test_OpenNeedsTheTradersSignature() public {
        OpenRequest memory request = openRequest(alice, BTC, true, 100e18, 10);
        bytes memory signature = sign(perps, keyOf[bob], request);

        vm.expectRevert(IPerpetualFutures.InvalidSignature.selector);
        vm.prank(executor);
        perps.openPosition(request, signature, new bytes[](0));
    }

    function test_TamperedOpenRequestIsRejected() public {
        OpenRequest memory request = openRequest(alice, BTC, true, 100e18, 10);
        bytes memory signature = sign(perps, keyOf[alice], request);
        request.leverage = 1000;

        vm.expectRevert(IPerpetualFutures.InvalidSignature.selector);
        vm.prank(executor);
        perps.openPosition(request, signature, new bytes[](0));
    }

    function test_OpenSignatureCannotBeReplayed() public {
        OpenRequest memory request = openRequest(alice, BTC, true, 100e18, 10);
        bytes memory signature = sign(perps, keyOf[alice], request);
        vm.startPrank(executor);
        perps.openPosition(request, signature, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(NoncesUpgradeable.InvalidAccountNonce.selector, alice, request.nonce + 1)
        );
        perps.openPosition(request, signature, new bytes[](0));
        vm.stopPrank();
    }

    function test_ExpiredSignatureIsRejected() public {
        OpenRequest memory request = openRequest(alice, BTC, true, 100e18, 10);
        request.deadline = block.timestamp - 1;
        bytes memory signature = sign(perps, keyOf[alice], request);

        vm.expectRevert(IPerpetualFutures.SignatureExpired.selector);
        vm.prank(executor);
        perps.openPosition(request, signature, new bytes[](0));
    }

    function test_DefaultNonceKeyIsSequential() public {
        OpenRequest memory request = openRequest(alice, BTC, true, 100e18, 10);
        request.nonce = 2;
        bytes memory signature = sign(perps, keyOf[alice], request);
        vm.expectRevert(abi.encodeWithSelector(NoncesUpgradeable.InvalidAccountNonce.selector, alice, 0));
        vm.prank(executor);
        perps.openPosition(request, signature, new bytes[](0));

        for (uint256 nonce; nonce < 3; ++nonce) {
            request.nonce = nonce;
            open(request, new bytes[](0));
        }
        assertEq(perps.nonces(alice), 3);
    }

    function test_KeyedNoncesLetOrdersLandInAnyOrder() public {
        OpenRequest memory first = openRequest(alice, BTC, true, 100e18, 10);
        OpenRequest memory second = openRequest(alice, ETH, false, 100e18, 10);

        uint256 b = open(second, new bytes[](0));
        uint256 a = open(first, new bytes[](0));

        assertEq(position(a).instrumentId, BTC);
        assertEq(position(b).instrumentId, ETH);
    }

    function test_ExecutorClosesOnTheTradersBehalf() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        uint256 before = wallet(alice);

        vm.expectEmit(address(perps));
        emit IPerpetualFutures.PositionClosed(id, alice, BTC_PRICE, 0, 0, 0, 0, 100e18);
        closeWithSig(alice, list(id));

        assertFalse(position(id).isOpen);
        assertEq(wallet(alice) - before, 100e18);
        assertEq(wallet(executor), 0);
    }

    function test_CloseSignatureOnlyClosesTheSignersPositions() public {
        uint256 own = open(alice, BTC, true, 100e18, 10);
        uint256 foreign = open(bob, BTC, true, 100e18, 10);

        closeWithSig(alice, list(own, foreign));

        assertFalse(position(own).isOpen);
        assertTrue(position(foreign).isOpen);
    }

    function test_OnlyExecutorClosesWithSignature() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        CloseRequest memory request = closeRequest(alice, list(id));
        bytes memory signature = sign(perps, keyOf[alice], request);

        vm.expectRevert(IPerpetualFutures.NotExecutor.selector);
        vm.prank(alice);
        perps.closePositionsWithSig(request, signature, new bytes[](0));
    }

    function test_TamperedCloseRequestIsRejected() public {
        uint256 a = open(alice, BTC, true, 100e18, 10);
        uint256 b = open(alice, BTC, true, 100e18, 10);
        CloseRequest memory request = closeRequest(alice, list(a));
        bytes memory signature = sign(perps, keyOf[alice], request);
        request.positionIds = list(a, b);

        vm.expectRevert(IPerpetualFutures.InvalidSignature.selector);
        vm.prank(executor);
        perps.closePositionsWithSig(request, signature, new bytes[](0));
    }

    function test_CloseSignatureCannotBeReplayed() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        CloseRequest memory request = closeRequest(alice, list(id));
        bytes memory signature = sign(perps, keyOf[alice], request);
        vm.startPrank(executor);
        perps.closePositionsWithSig(request, signature, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(NoncesUpgradeable.InvalidAccountNonce.selector, alice, request.nonce + 1)
        );
        perps.closePositionsWithSig(request, signature, new bytes[](0));
        vm.stopPrank();
    }
}
