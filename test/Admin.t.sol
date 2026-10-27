// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {PerpsTest} from "./utils/PerpsTest.sol";
import {PerpetualFutures} from "../src/PerpetualFutures.sol";
import {Config, InstrumentLib} from "../src/InstrumentLib.sol";
import {PositionLib} from "../src/PositionLib.sol";
import {IPerpetualFutures, OpenRequest} from "../src/interfaces/IPerpetualFutures.sol";

contract AdminTest is PerpsTest {
    function test_CannotBeInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        perps.initialize(bob, address(pyth), address(usdt));

        PerpetualFutures implementation = new PerpetualFutures();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(bob, address(pyth), address(usdt));
    }

    function test_OnlyOwnerChangesParameters() public {
        address implementation = address(new PerpetualFutures());
        bytes memory unauthorized = abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bob);
        vm.startPrank(bob);

        vm.expectRevert(unauthorized);
        perps.setMaxPriceAge(60);
        vm.expectRevert(unauthorized);
        perps.setExecutor(bob, true);
        vm.expectRevert(unauthorized);
        perps.setFeeRates(0, 0, 0);
        vm.expectRevert(unauthorized);
        perps.setTradeMinimums(0, 0);
        vm.expectRevert(unauthorized);
        perps.addInstrument(launchConfig(keccak256("SOL"), 100e18), "SOL");
        vm.expectRevert(unauthorized);
        perps.setLiquidationBuffer(BTC, 0);
        vm.expectRevert(unauthorized);
        perps.setHaircutConfig(BTC, 1, 1, 1, 0);
        vm.expectRevert(unauthorized);
        perps.withdrawNative(bob, 1);
        vm.expectRevert(unauthorized);
        perps.upgradeToAndCall(implementation, "");

        vm.stopPrank();
    }

    function test_OwnerAddsAMarket() public {
        bytes32 solFeed = keccak256("SOL");
        vm.expectEmit(address(perps));
        emit IPerpetualFutures.InstrumentAdded(3, solFeed, "SOL");
        vm.prank(owner);
        uint32 sol = perps.addInstrument(launchConfig(solFeed, 100e18), "SOL");

        assertEq(sol, 3);
        assertEq(perps.instrumentCount(), 4);
    }

    function test_InvalidMarketConfigIsRejected() public {
        Config memory config = launchConfig(bytes32(0), 100e18);
        vm.startPrank(owner);

        vm.expectRevert(InstrumentLib.InvalidInstrumentConfig.selector);
        perps.addInstrument(config, "NONE");
        vm.expectRevert(InstrumentLib.InvalidInstrumentConfig.selector);
        perps.setLiquidationBuffer(BTC, 1e18);
        vm.expectRevert(InstrumentLib.InvalidInstrumentConfig.selector);
        perps.setHaircutConfig(BTC, 0, 1e18, 1e18, 0.1e18);
        vm.expectRevert(InstrumentLib.InvalidInstrumentConfig.selector);
        perps.setHaircutConfig(BTC, 1e18, 1e18, 0, 0.1e18);
        vm.expectRevert(InstrumentLib.InvalidInstrumentConfig.selector);
        perps.setHaircutConfig(BTC, 1e18, 1e18, 1e18, 1e18);
        vm.expectRevert(InstrumentLib.InvalidInstrumentId.selector);
        perps.setLiquidationBuffer(7, 0.0005e18);

        vm.stopPrank();
    }

    function test_QueuePayoutsDoNotNeedAPrice() public {
        uint256 owed = winBtc(alice);
        lose(1_000e18);
        skip(1 hours);
        uint256 before = wallet(alice);

        perps.harvest(10);

        assertEq(wallet(alice) - before, owed / SCALE * SCALE);
    }

    function test_PriceOlderThanFiveSecondsIsRejected() public {
        setPrice(BTC, BTC_PRICE);
        skip(MAX_PRICE_AGE);
        uint256 id = open(alice, BTC, true, 100e18, 1000);

        skip(1);
        vm.expectRevert(PythErrors.StalePrice.selector);
        open(alice, BTC, true, 100e18, 10);
        vm.expectRevert(PythErrors.StalePrice.selector);
        close(alice, id);
        vm.expectRevert(PythErrors.StalePrice.selector);
        liquidate(id);
    }

    function test_TradeCarriesItsOwnPythUpdateAndContractPaysTheFee() public {
        skip(1);
        bytes[] memory update = priceUpdate(BTC, int64(101_000e8), -8);
        assertEq(perps.pythUpdateFee(update), 1);
        assertEq(perps.pythUpdateFee(new bytes[](0)), 0);
        uint256 balanceBefore = address(perps).balance;

        uint256 id = open(openRequest(alice, BTC, true, 100e18, 10), update);

        assertEq(position(id).entryPrice, 101_000e8);
        assertEq(balanceBefore - address(perps).balance, 1);
    }

    function test_TradeRevertsWhenContractCannotPayTheUpdateFee() public {
        skip(1);
        bytes[] memory update = priceUpdate(BTC, int64(101_000e8), -8);
        vm.deal(address(perps), 0);
        OpenRequest memory request = openRequest(alice, BTC, true, 100e18, 10);

        vm.expectRevert(IPerpetualFutures.InsufficientUpdateFee.selector);
        open(request, update);
    }

    function test_PythExponentIsNormalized() public {
        setPrice(BTC, int64(100_000e10), -10);
        uint256 a = open(alice, BTC, true, 100e18, 10);
        setPrice(BTC, int64(100_000e5), -5);
        uint256 b = open(alice, BTC, true, 100e18, 10);

        assertEq(position(a).entryPrice, BTC_PRICE);
        assertEq(position(b).entryPrice, BTC_PRICE);
    }

    function test_NonPositivePriceIsRejected() public {
        setPrice(BTC, int64(0), -8);
        vm.expectRevert(InstrumentLib.InvalidPrice.selector);
        open(alice, BTC, true, 100e18, 10);

        setPrice(BTC, int64(-1), -8);
        vm.expectRevert(InstrumentLib.InvalidPrice.selector);
        open(alice, BTC, true, 100e18, 10);
    }

    function test_LimitsChangeAtOnce() public {
        vm.prank(owner);
        perps.setTradeMinimums(5e18, 100e18);

        vm.expectRevert(PositionLib.CollateralBelowMinimum.selector);
        open(alice, BTC, true, 4e18, 100);
        vm.expectRevert(PositionLib.NotionalBelowMinimum.selector);
        open(alice, BTC, true, 50e18, 1);
    }

    function test_OwnerUpgradeKeepsPositionsAndQueue() public {
        uint256 owed = winBtc(bob);
        uint256 id = open(alice, BTC, true, 100e18, 10);
        address implementation = address(new PerpetualFutures());

        vm.prank(owner);
        perps.upgradeToAndCall(implementation, "");

        assertTrue(position(id).isOpen);
        assertEq(queued(bob), owed);
        assertEq(perps.totalLockedMargin(), 100e18);
        uint256 before = wallet(alice);
        close(alice, id);
        assertEq(wallet(alice) - before, 100e18);
    }

    function test_OwnerCanOnlyWithdrawNativeCoin() public {
        uint256 margin = 100e18;
        open(alice, BTC, true, margin, 10);
        uint256 tokens = usdt.balanceOf(address(perps));

        vm.prank(owner);
        perps.withdrawNative(owner, 0.5 ether);

        assertEq(owner.balance, 0.5 ether);
        assertEq(usdt.balanceOf(address(perps)), tokens);
        assertEq(perps.totalLockedMargin(), margin);
    }
}
