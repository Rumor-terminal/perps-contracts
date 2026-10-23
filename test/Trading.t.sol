// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PerpsTest} from "./utils/PerpsTest.sol";
import {InstrumentLib} from "../src/InstrumentLib.sol";
import {Position, PositionLib} from "../src/PositionLib.sol";
import {IPerpetualFutures} from "../src/interfaces/IPerpetualFutures.sol";

contract TradingTest is PerpsTest {
    function test_OpeningTakesExactlyTheMarginAndNothingElse() public {
        uint256 before = wallet(alice);
        uint256 id = open(alice, BTC, true, 50e18, 100);

        assertEq(before - wallet(alice), 50e18);
        assertEq(perps.totalLockedMargin(), 50e18);
        assertEq(wallet(owner), 0);

        Position memory p = position(id);
        assertEq(p.trader, alice);
        assertEq(p.instrumentId, BTC);
        assertEq(p.collateral, 50e18);
        assertEq(p.leverage, 100);
        assertEq(p.debited, 0);
        assertTrue(p.isLong);
        assertTrue(p.isOpen);
    }

    function test_OpenEmitsPositionOpened() public {
        vm.expectEmit(address(perps));
        emit IPerpetualFutures.PositionOpened(0, alice, BTC, true, uint64(BTC_PRICE), 50e18, 100);
        open(alice, BTC, true, 50e18, 100);
    }

    function test_LongAndShortOpenAtTheSamePythPrice() public {
        uint256 longId = open(alice, BTC, true, 100e18, 1000);
        uint256 shortId = open(bob, BTC, false, 100e18, 1000);

        assertEq(position(longId).entryPrice, BTC_PRICE);
        assertEq(position(shortId).entryPrice, BTC_PRICE);
    }

    function test_PositionSizeIsMarginTimesLeverage() public {
        uint256 id = open(alice, BTC, true, 50e18, 100);

        (int256 rawPnl, int256 pnl) = perps.previewPnl(id, movedPrice(BTC_PRICE, -50));
        assertEq(rawPnl, -25e18);
        assertEq(pnl, -25e18);
    }

    function test_MinimumMarginIsOneDollar() public {
        open(alice, BTC, true, 1e18, 1000);

        vm.expectRevert(PositionLib.CollateralBelowMinimum.selector);
        open(alice, BTC, true, 0.99e18, 1000);
    }

    function test_MinimumPositionSizeIsTenDollars() public {
        open(alice, BTC, true, 10e18, 1);
        open(alice, BTC, true, 1e18, 10);

        vm.expectRevert(PositionLib.NotionalBelowMinimum.selector);
        open(alice, BTC, true, 9.99e18, 1);

        vm.expectRevert(PositionLib.NotionalBelowMinimum.selector);
        open(alice, BTC, true, 1e18, 9);
    }

    function test_ZeroLeverageIsRejected() public {
        open(alice, BTC, true, 10e18, 1);
        open(alice, BTC, true, 10e18, 1000);

        vm.expectRevert(PositionLib.ZeroLeverage.selector);
        open(alice, BTC, true, 10e18, 0);
    }

    function test_OnlyListedMarketsCanBeTraded() public {
        vm.expectRevert(InstrumentLib.InvalidInstrumentId.selector);
        open(alice, 3, true, 100e18, 10);
    }

    function test_MarginFinerThanUsdtPrecisionIsRejected() public {
        vm.expectRevert(PositionLib.CollateralPrecision.selector);
        open(alice, BTC, true, 10e18 + 1, 10);
    }

    function test_SeveralPositionsOnOneMarketIncludingLongAndShort() public {
        uint256 a = open(alice, BTC, true, 100e18, 10);
        uint256 b = open(alice, BTC, true, 50e18, 20);
        uint256 c = open(alice, BTC, false, 100e18, 10);

        uint256[] memory ids = perps.openPositionIds(alice);
        assertEq(ids.length, 3);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
        assertEq(ids[2], c);
    }

    function test_LosingCloseReturnsMarginMinusTheLoss() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        setPrice(BTC, movedPrice(BTC_PRICE, -300));

        uint256 before = wallet(alice);
        close(alice, id);

        assertEq(wallet(alice) - before, 70e18);
        assertEq(pool(), 29.4e18);
        assertEq(perps.totalLockedMargin(), 0);
        assertFalse(position(id).isOpen);
        assertEq(perps.openPositionIds(alice).length, 0);
    }

    function test_ShortProfitsWhenPriceFalls() public {
        lose(1_000e18);
        uint256 id = open(alice, BTC, false, 100e18, 10);
        uint256 mark = movedPrice(BTC_PRICE, -300);
        setPrice(BTC, mark);
        uint256 net = netProfit(id, mark);

        uint256 before = wallet(alice);
        close(alice, id);

        assertGt(net, 0);
        assertEq(wallet(alice) - before, 100e18 + net / SCALE * SCALE);
    }

    function test_CloseEmitsPositionClosedAtThePythPrice() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        uint256 mark = movedPrice(BTC_PRICE, -300);
        setPrice(BTC, mark);

        vm.expectEmit(address(perps));
        emit IPerpetualFutures.PositionClosed(id, alice, mark, -30e18, -30e18, 0.6e18);
        close(alice, id);
    }

    function test_LossNeverExceedsTheMargin() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        uint256 other = open(alice, ETH, false, 100e18, 10);
        setPrice(BTC, movedPrice(BTC_PRICE, -5_000));

        uint256 before = wallet(alice);
        close(alice, id);

        assertEq(wallet(alice), before);
        assertEq(pool(), 98e18);
        assertTrue(position(other).isOpen);
        assertEq(perps.totalLockedMargin(), 100e18);
    }

    function test_DeadZoneTurnsATinyGainIntoZero() public {
        uint256 longId = open(alice, BTC, true, 100e18, 1000);
        uint256 shortId = open(bob, BTC, false, 100e18, 1000);

        (int256 rawLong, int256 pnlLong) = perps.previewPnl(longId, BTC_PRICE + 1e8);
        (int256 rawShort, int256 pnlShort) = perps.previewPnl(shortId, BTC_PRICE - 1e8);
        assertEq(rawLong, 0);
        assertEq(pnlLong, 0);
        assertEq(rawShort, 0);
        assertEq(pnlShort, 0);

        setPrice(BTC, BTC_PRICE + 1e8);
        uint256 before = wallet(alice);
        close(alice, longId);

        assertEq(wallet(alice) - before, 100e18);
        assertEq(pool(), 0);
        assertEq(perps.queueLength(), 0);
    }

    function test_OnlyTheOwnerCanCloseAPosition() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        uint256 before = wallet(alice);

        close(bob, id);

        assertTrue(position(id).isOpen);
        assertEq(wallet(alice), before);
    }

    function test_AClosedPositionCannotBeClosedAgain() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        close(alice, id);
        uint256 before = wallet(alice);

        close(alice, id);

        assertEq(wallet(alice), before);
        assertEq(perps.totalLockedMargin(), 0);
    }

    function test_CloseAllClosesEveryPositionAcrossMarkets() public {
        uint256 a = open(alice, BTC, true, 100e18, 10);
        uint256 b = open(alice, ETH, false, 100e18, 10);
        uint256 c = open(alice, BNB, true, 100e18, 10);
        uint256 before = wallet(alice);

        closeAll(alice, list(a, b, c));

        assertEq(wallet(alice) - before, 300e18);
        assertEq(perps.openPositionIds(alice).length, 0);
        assertEq(perps.totalLockedMargin(), 0);
    }

    function test_StatsRecordVolumeAndRealizedLoss() public {
        uint256 id = open(alice, BTC, true, 100e18, 10);
        setPrice(BTC, movedPrice(BTC_PRICE, -300));
        close(alice, id);

        (uint128 volume,, uint128 loss,,, uint32 positions,) = perps.traderStats(alice);
        assertEq(volume, 1_000e18);
        assertEq(loss, 30e18);
        assertEq(positions, 1);

        (uint128 totalVolume,, uint128 totalLoss,,,,) = perps.totalStats();
        assertEq(totalVolume, 1_000e18);
        assertEq(totalLoss, 30e18);
    }
}
