// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PerpsTest} from "./utils/PerpsTest.sol";

contract WinHaircutTest is PerpsTest {
    function test_WorkedExample() public {
        lose(1_000e18);
        uint256 feesBefore = wallet(owner);
        uint256 id = open(alice, BTC, true, 100e18, 100);
        setPrice(BTC, 102_000e8);

        (int256 rawPnl, int256 pnl) = perps.previewPnl(id, 102_000e8);
        assertEq(rawPnl, 199.8e18);
        assertApproxEqAbs(pnl, 178.13e18, 0.005e18);

        uint256 before = wallet(alice);
        close(alice, id);

        assertApproxEqAbs(wallet(alice) - before, 274.57e18, 0.005e18);
        assertApproxEqAbs(wallet(owner) - feesBefore, 3.56e18, 0.005e18);
    }

    function test_ShareOfGainKeptMatchesTheTable() public {
        uint16[6] memory moves = [uint16(5), 10, 20, 50, 100, 500];
        uint8[6][3] memory kept =
            [[uint8(61), 72, 80, 85, 86, 88], [uint8(54), 68, 77, 83, 86, 88], [uint8(37), 53, 67, 78, 83, 87]];

        for (uint32 market; market < 3; ++market) {
            uint256 entry = currentPrice(market);
            uint256 id = open(alice, market, true, 100e18, 100);
            for (uint256 i; i < moves.length; ++i) {
                uint256 rawGain = 10_000e18 * uint256(moves[i]) / 10_000;
                uint256 received = netProfit(id, movedPrice(entry, int256(uint256(moves[i]))));
                assertApproxEqAbs(received * 100e18 / rawGain, uint256(kept[market][i]) * 1e18, 0.5e18);
            }
        }
    }

    function test_SmallBtcMoveKeepsSevenTwentyFourOfTenDollars() public {
        uint256 id = open(alice, BTC, true, 100e18, 100);
        assertApproxEqAbs(netProfit(id, movedPrice(BTC_PRICE, 10)), 7.24e18, 0.005e18);
    }

    function test_HaircutNeverAppliesToALoss() public {
        uint256 longId = open(alice, BTC, true, 100e18, 10);
        uint256 shortId = open(alice, BTC, false, 100e18, 10);

        (int256 rawLong, int256 pnlLong) = perps.previewPnl(longId, movedPrice(BTC_PRICE, -100));
        (int256 rawShort, int256 pnlShort) = perps.previewPnl(shortId, movedPrice(BTC_PRICE, 100));

        assertEq(rawLong, -10e18);
        assertEq(pnlLong, -10e18);
        assertEq(rawShort, -10e18);
        assertEq(pnlShort, -10e18);
    }

    function testFuzz_HaircutDoesNotDependOnSizeOrLeverage(uint256 margin, uint256 leverage, uint256 bps, bool isLong)
        public
    {
        margin = bound(margin, 10, 1_000) * 1e18;
        leverage = bound(leverage, 1, 1_000);
        int256 move = int256(bound(bps, 1, 5_000)) * (isLong ? int256(1) : -1);

        uint256 baseline = open(alice, BTC, isLong, 100e18, 100);
        uint256 id = open(alice, BTC, isLong, margin, leverage);
        uint256 mark = movedPrice(BTC_PRICE, move);

        (int256 rawRef, int256 pnlRef) = perps.previewPnl(baseline, mark);
        (int256 raw, int256 pnl) = perps.previewPnl(id, mark);

        assertApproxEqRel(uint256(pnl) * 1e18 / uint256(raw), uint256(pnlRef) * 1e18 / uint256(rawRef), 1e9);
    }

    function testFuzz_PoolAlwaysKeepsAtLeastTenPercent(uint256 marketSeed, uint256 bps, bool isLong) public {
        uint32 market = uint32(bound(marketSeed, 0, 2));
        int256 move = isLong ? int256(bound(bps, 1, 100_000)) : -int256(bound(bps, 1, 9_999));
        uint256 entry = currentPrice(market);
        uint256 id = open(alice, market, isLong, 100e18, 100);

        (int256 raw, int256 pnl) = perps.previewPnl(id, movedPrice(entry, move));

        assertGt(raw, 0);
        assertLe(uint256(pnl) * 10, uint256(raw) * 9);
    }

    function testFuzz_BiggerMovesKeepMore(uint256 marketSeed, uint256 smaller, uint256 bigger) public {
        uint32 market = uint32(bound(marketSeed, 0, 2));
        smaller = bound(smaller, 1, 5_000);
        bigger = bound(bigger, smaller, 5_000);
        uint256 entry = currentPrice(market);
        uint256 id = open(alice, market, true, 100e18, 100);

        assertLe(
            keptShare(id, movedPrice(entry, int256(smaller))), keptShare(id, movedPrice(entry, int256(bigger))) + 2
        );
    }

    function test_LargeMovesKeepAlmostNinetyPercent() public {
        for (uint32 market; market < 3; ++market) {
            uint256 entry = currentPrice(market);
            uint256 id = open(alice, market, true, 100e18, 10);
            uint256 share = keptShare(id, movedPrice(entry, 10_000));
            assertGe(share, 0.899e18);
            assertLe(share, 0.9e18);
        }
    }

    function keptShare(uint256 id, uint256 mark) internal view returns (uint256) {
        (int256 raw, int256 pnl) = perps.previewPnl(id, mark);
        return uint256(pnl) * 1e18 / uint256(raw);
    }
}
