// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {Exchange} from "../src/Exchange.sol";
import {IExchange} from "../src/interfaces/IExchange.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract ExchangeTest is Test {
    bytes32 constant BTC = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant ETH = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    uint64 constant P8 = 1e8;
    uint256 constant WALLET = 100_000e6;

    MockPyth pyth;
    MockUSDC usdc;
    Exchange ex;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");
    bytes[] noUpdate;

    function setUp() public {
        vm.warp(1_700_000_000);
        pyth = new MockPyth(60, 1);
        usdc = new MockUSDC();
        ex = new Exchange(owner, address(pyth), address(usdc));
        vm.startPrank(owner);
        ex.setTradeMinimums(10e18, 1000e18);
        ex.addInstrument(_instrument(BTC), 1e8, "BTC");
        ex.addInstrument(_instrument(ETH), 1e8, "ETH");
        vm.stopPrank();
        setPrice(BTC, 80_000 * P8);
        setPrice(ETH, 4_000 * P8);
        fundHouse(1_000_000e6);
        fundWallet(alice, WALLET);
        fundWallet(bob, WALLET);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(liquidator, 1 ether);
    }

    function _instrument(bytes32 priceId) internal pure returns (IExchange.Instrument memory) {
        return IExchange.Instrument({
            impactA: 1e21,
            impactB: 1e18,
            priceId: priceId,
            maxLeverage: 1000,
            maxNotional: 1_000_000e18,
            liquidationBuffer: 0.0005e18,
            profitHaircut: 0.05e18,
            impactC: 1e20
        });
    }

    function updateData(bytes32 id, uint64 price8) internal returns (bytes[] memory data) {
        vm.warp(block.timestamp + 1);
        data = new bytes[](1);
        data[0] = pyth.createPriceFeedUpdateData(
            id, int64(price8), price8 / 1000, -8, int64(price8), price8 / 1000, uint64(block.timestamp), 0
        );
    }

    function setPrice(bytes32 id, uint64 price8) internal {
        bytes[] memory data = updateData(id, price8);
        pyth.updatePriceFeeds{value: 1}(data);
    }

    function fundHouse(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(ex), amount);
        ex.fundHouse(amount);
    }

    function fundWallet(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(ex), type(uint256).max);
    }

    function open(address who, uint32 inst, bool isLong, uint128 collateral, uint32 lev) internal returns (uint256) {
        vm.prank(who);
        return ex.openPosition(inst, isLong, collateral, lev, noUpdate);
    }

    function close(address who, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(who);
        ex.closePositions(ids, noUpdate);
    }

    function testOpenPullsCollateralFromWallet() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        (address posOwner,, uint64 entry, uint128 coll, uint32 lev,, bool isLong,, bool isOpen) = ex.positions(id);
        assertEq(posOwner, alice);
        assertEq(entry, 80_000 * P8);
        assertEq(coll, 1_000e18);
        assertEq(lev, 10);
        assertTrue(isLong && isOpen);
        assertEq(usdc.balanceOf(alice), WALLET - 1_000e6);
        assertEq(ex.balances(alice), 0);
        assertEq(ex.totalBalances(), 0);
        assertEq(ex.totalLockedMargin(), 1_000e18);
        assertEq(ex.treasury(), 1_000_000e18 + 1_000e18);
        assertEq(usdc.balanceOf(address(ex)), 1_001_000e6);
        (uint96 longSize,,,,) = ex.getMarketOi(0);
        assertEq(longSize, uint96(10_000e18 * 1e8 / (80_000 * P8)));
    }

    function testCollateralMustMatchTokenPrecision() public {
        vm.prank(alice);
        vm.expectRevert(IExchange.CollateralPrecision.selector);
        ex.openPosition(0, true, 1_000e18 + 1, 10, noUpdate);
    }

    function testOpenLongCloseWithProfit() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        setPrice(BTC, 88_000 * P8);
        (int256 rawPnl, int256 pnl) = ex.previewPnl(id, 88_000 * P8);
        assertGt(rawPnl, 0);
        assertGt(pnl, 0);
        assertLt(pnl, rawPnl);

        uint256 houseBefore = ex.queueHarvestAvailable();
        close(alice, id);
        (,,,,,,,, bool isOpen) = ex.positions(id);
        assertFalse(isOpen);
        uint256 fee = uint256(pnl) * 0.02e18 / 1e18;
        assertEq(ex.balances(alice), 1_000e18 + uint256(pnl) - fee);
        assertEq(usdc.balanceOf(alice), WALLET - 1_000e6);
        assertEq(ex.protocolFeeAccumulator(), fee);
        assertEq(ex.totalLockedMargin(), 0);
        assertEq(ex.queueHarvestAvailable(), houseBefore - uint256(pnl));
        assertEq(ex.getUserOpenPositionIds(alice).length, 0);
        (uint96 longSize,,,,) = ex.getMarketOi(0);
        assertEq(longSize, 0);
    }

    function testClaimUnclaimedBalance() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        setPrice(BTC, 88_000 * P8);
        close(alice, id);
        uint256 unclaimed = ex.balances(alice);
        assertGt(unclaimed, 1_000e18);
        uint256 treasuryBefore = ex.treasury();

        vm.prank(alice);
        ex.claim(500e6);
        assertEq(ex.balances(alice), unclaimed - 500e18);
        assertEq(usdc.balanceOf(alice), WALLET - 1_000e6 + 500e6);
        assertEq(ex.treasury(), treasuryBefore - 500e18);

        vm.prank(alice);
        vm.expectRevert(IExchange.InsufficientBalance.selector);
        ex.claim(uint256(unclaimed) / 1e12);

        vm.prank(alice);
        vm.expectRevert(IExchange.ZeroAmount.selector);
        ex.claim(0);
    }

    function testUnclaimedBalanceReducesWalletPull() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        setPrice(BTC, 88_000 * P8);
        close(alice, id);
        uint256 unclaimed = ex.balances(alice);
        uint256 walletBefore = usdc.balanceOf(alice);

        uint128 collateral = uint128(unclaimed - (unclaimed % 1e12) + 500e18);
        vm.prank(alice);
        ex.openPosition(0, true, collateral, 10, noUpdate);
        assertEq(ex.balances(alice), unclaimed % 1e12);
        assertEq(usdc.balanceOf(alice), walletBefore - 500e6);
        assertEq(ex.totalLockedMargin(), collateral);

        vm.prank(alice);
        ex.openPosition(0, false, 1_000e18, 10, noUpdate);
        assertEq(ex.balances(alice), unclaimed % 1e12);
        assertEq(usdc.balanceOf(alice), walletBefore - 500e6 - 1_000e6);
    }

    function testOpenShortCloseWithLoss() public {
        uint256 id = open(alice, 0, false, 1_000e18, 5);
        setPrice(BTC, 84_000 * P8);
        (, int256 pnl) = ex.previewPnl(id, 84_000 * P8);
        assertEq(pnl, -250e18);
        close(alice, id);
        uint256 fee = 250e18 * 0.02e18 / 1e18;
        assertEq(ex.balances(alice), 750e18);
        assertEq(ex.protocolFeeAccumulator(), fee);
        assertEq(ex.queueHarvestAvailable(), 1_000_000e18 + 250e18 - fee);
    }

    function testLossCappedByCollateral() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        setPrice(BTC, 60_000 * P8);
        (int256 rawPnl, int256 pnl) = ex.previewPnl(id, 60_000 * P8);
        assertEq(rawPnl, -2_500e18);
        assertEq(pnl, -1_000e18);
    }

    function testTinyMoveGivesNoProfit() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        (, int256 pnl) = ex.previewPnl(id, 80_000 * P8 + 1);
        assertEq(pnl, 0);
    }

    function testLiquidationPriceFormula() public {
        uint256 longId = open(alice, 0, true, 1_000e18, 10);
        uint256 shortId = open(bob, 0, false, 1_000e18, 10);
        uint256 base = 80_000 * P8 - 8_000 * P8;
        assertEq(ex.liquidationPrice(longId), uint64(base + base * 0.0005e18 / 1e18));
        uint256 shortBase = 80_000 * P8 + 8_000 * P8;
        assertEq(ex.liquidationPrice(shortId), uint64(shortBase - shortBase * 0.0005e18 / 1e18));
    }

    function testLiquidateLong() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        uint64 liq = ex.liquidationPrice(id);
        setPrice(BTC, liq + 1);
        vm.prank(liquidator);
        vm.expectRevert(IExchange.NotLiquidatable.selector);
        ex.liquidate(id, noUpdate);

        setPrice(BTC, liq);
        vm.prank(liquidator);
        ex.liquidate(id, noUpdate);
        (,,,,,,,, bool isOpen) = ex.positions(id);
        assertFalse(isOpen);
        assertEq(ex.balances(alice), 0);
        assertEq(ex.totalLockedMargin(), 0);
        uint256 fee = 1_000e18 * 0.02e18 / 1e18;
        assertEq(ex.protocolFeeAccumulator(), fee);
        assertEq(ex.queueHarvestAvailable(), 1_000_000e18 + 1_000e18 - fee);
    }

    function testLiquidateBatchSkipsHealthy() public {
        uint256 a = open(alice, 0, true, 1_000e18, 10);
        uint256 b = open(bob, 1, true, 1_000e18, 2);
        setPrice(BTC, 70_000 * P8);
        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = 999;
        vm.prank(liquidator);
        uint256 n = ex.liquidateBatch(ids, noUpdate);
        assertEq(n, 1);
        (,,,,,,,, bool bOpen) = ex.positions(b);
        assertTrue(bOpen);
    }

    function testPriceUpdateInTxAndFeeRefund() public {
        bytes[] memory data = updateData(BTC, 90_000 * P8);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 id = ex.openPosition{value: 0.01 ether}(0, true, 1_000e18, 10, data);
        (,, uint64 entry,,,,,,) = ex.positions(id);
        assertEq(entry, 90_000 * P8);
        assertEq(alice.balance, balBefore - 1);
        assertEq(address(ex).balance, 0);
    }

    function testInsufficientUpdateFeeReverts() public {
        bytes[] memory data = updateData(BTC, 90_000 * P8);
        vm.prank(alice);
        vm.expectRevert(IExchange.InsufficientUpdateFee.selector);
        ex.openPosition{value: 0}(0, true, 1_000e18, 10, data);
    }

    function testStalePriceReverts() public {
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        vm.expectRevert(PythErrors.StalePrice.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);
    }

    function testOpenParamChecks() public {
        vm.startPrank(alice);
        vm.expectRevert(IExchange.TradeBelowMinimum.selector);
        ex.openPosition(0, true, 9e18, 10, noUpdate);
        vm.expectRevert(IExchange.NotionalBelowMinimum.selector);
        ex.openPosition(0, true, 10e18, 10, noUpdate);
        vm.expectRevert(IExchange.LeverageTooHigh.selector);
        ex.openPosition(0, true, 1_000e18, 1001, noUpdate);
        vm.expectRevert(IExchange.LeverageTooLow.selector);
        ex.openPosition(0, true, 1_000e18, 0, noUpdate);
        vm.expectRevert(IExchange.PositionTooLarge.selector);
        ex.openPosition(0, true, 10_000e18, 101, noUpdate);
        vm.expectRevert(IExchange.InvalidInstrumentId.selector);
        ex.openPosition(7, true, 1_000e18, 10, noUpdate);
        vm.expectRevert();
        ex.openPosition(0, true, 100_001e18, 1, noUpdate);
        vm.stopPrank();
    }

    function testOiCap() public {
        vm.prank(owner);
        ex.setMarketOiCaps(0, uint128(10_000e18 * 1e8 / (80_000 * P8)), type(uint128).max);
        open(alice, 0, true, 1_000e18, 10);
        vm.prank(bob);
        vm.expectRevert(IExchange.OiCapExceeded.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);
        open(bob, 0, false, 1_000e18, 10);
    }

    function testTradingPause() public {
        vm.prank(owner);
        ex.setTradingPaused(true);
        vm.prank(alice);
        vm.expectRevert(IExchange.TradingPaused.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);
    }

    function testProfitQueuedWhenHouseEmptyAndCreditsTradeable() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        uint256 id = open(alice, 0, true, 40_000e18, 25);
        setPrice(BTC, 200_000 * P8);
        (, int256 pnl) = ex.previewPnl(id, 200_000 * P8);
        assertGt(uint256(pnl), 1_000_000e18);
        close(alice, id);

        uint256 fee = uint256(pnl) * 0.02e18 / 1e18;
        uint256 owed = uint256(pnl) - fee;
        uint256 paidNow = 1_000_000e18;
        assertEq(ex.balances(alice), 40_000e18 + paidNow);
        assertEq(ex.totalQueued(), owed - paidNow);
        assertEq(ex.userQueuedTotal(alice), owed - paidNow);
        assertEq(ex.lpBankrollAvailable(), 0);
        assertEq(ex.protocolFeeAccumulator(), 0);

        uint256 credit = 5_000e18;
        vm.prank(alice);
        uint256 creditId = ex.openPosition(1, true, uint128(credit), 2, noUpdate);
        assertEq(ex.userQueuedTotal(alice), owed - paidNow - credit);
        (,,,,,,, bool usedCredits,) = ex.positions(creditId);
        assertTrue(usedCredits);
        assertEq(ex.totalLockedMargin(), 0);

        setPrice(ETH, 3_000 * P8);
        close(alice, creditId);
        assertEq(ex.userQueuedTotal(alice), owed - paidNow - credit + 2_500e18);
        assertEq(ex.sideBucket(), 0);
        assertEq(ex.harvest(10), 0);
    }

    function testHarvestPaysQueueFromNewLosses() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        uint256 id = open(alice, 0, true, 40_000e18, 25);
        setPrice(BTC, 200_000 * P8);
        close(alice, id);
        uint256 queued = ex.totalQueued();
        assertGt(queued, 0);

        uint256 bobId = open(bob, 0, false, 50_000e18, 2);
        setPrice(BTC, 400_000 * P8);
        close(bob, bobId);
        assertEq(ex.sideBucket(), 50_000e18);
        uint256 available = ex.queueHarvestAvailable();
        assertEq(available, 50_000e18);

        uint256 balBefore = ex.balances(alice);
        uint256 paid = ex.harvest(10);
        assertEq(paid, available < queued ? available : queued);
        assertEq(ex.balances(alice), balBefore + paid);
        assertEq(ex.totalQueued(), queued - paid);
    }

    function testFeeClaims() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        setPrice(BTC, 70_000 * P8);
        close(alice, id);
        uint256 fees = ex.protocolFeeAccumulator();
        assertGt(fees, 0);
        vm.prank(alice);
        vm.expectRevert();
        ex.claimProtocolFees();
        vm.prank(owner);
        ex.claimProtocolFees();
        assertEq(ex.balances(owner), fees);
        assertEq(ex.protocolFeeAccumulator(), 0);
    }

    function testCloseBatchMixed() public {
        uint256 a = open(alice, 0, true, 1_000e18, 10);
        uint256 b = open(alice, 1, false, 2_000e18, 3);
        uint256 c = open(bob, 0, true, 1_000e18, 10);
        setPrice(BTC, 82_000 * P8);
        setPrice(ETH, 4_100 * P8);
        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
        vm.prank(alice);
        ex.closePositions(ids, noUpdate);
        (,,,,,,,, bool cOpen) = ex.positions(c);
        assertTrue(cOpen);
        assertEq(ex.getUserOpenPositionIds(alice).length, 0);
        assertEq(ex.getUserOpenPositionIds(bob).length, 1);
    }

    function testFuzzLossNeverExceedsCollateral(uint64 mark, uint32 lev, bool isLong) public {
        mark = uint64(bound(mark, 1 * P8, 1_000_000 * P8));
        lev = uint32(bound(lev, 1, 1000));
        uint256 id = open(alice, 0, isLong, 1_000e18, lev);
        (int256 rawPnl, int256 pnl) = ex.previewPnl(id, mark);
        assertGe(pnl, -1_000e18);
        if (rawPnl > 0) {
            assertGe(pnl, 0);
            assertLe(pnl, rawPnl);
        } else {
            assertEq(pnl, rawPnl < -1_000e18 ? int256(-1_000e18) : rawPnl);
        }
    }

    function testFuzzLiquidationPriceSide(uint64 entry, uint32 lev) public view {
        entry = uint64(bound(entry, 1 * P8, 1_000_000 * P8));
        lev = uint32(bound(lev, 1, 1000));
        uint64 longLiq = ex.previewLiquidationPrice(0, entry, lev, true);
        uint64 shortLiq = ex.previewLiquidationPrice(0, entry, lev, false);
        assertLe(longLiq, entry);
        assertGe(shortLiq, entry);
    }

    function testSolvencyInvariantAfterRandomTrades(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 20));
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = r % 2 == 0 ? alice : bob;
            uint32 inst = uint32(r % 2);
            uint64 base = inst == 0 ? 80_000 * P8 : 4_000 * P8;
            uint64 px = uint64(base * (90 + (r >> 8) % 21) / 100);
            setPrice(inst == 0 ? BTC : ETH, px);
            uint32 lev = uint32(1 + (r >> 16) % 50);
            if (usdc.balanceOf(who) >= 1_000e6) {
                vm.prank(who);
                ex.openPosition(inst, (r >> 24) % 2 == 0, 1_000e18, lev, noUpdate);
            }
            uint256[] memory ids = ex.getUserOpenPositionIds(who);
            if (ids.length != 0 && (r >> 32) % 3 == 0) {
                uint256[] memory one = new uint256[](1);
                one[0] = ids[0];
                vm.prank(who);
                ex.closePositions(one, noUpdate);
            }
            uint256 unclaimed = ex.balances(who) / 1e12;
            if (unclaimed != 0 && (r >> 48) % 4 == 0) {
                vm.prank(who);
                ex.claim(unclaimed);
            }
        }
        uint256 liabilities = uint256(ex.totalBalances()) + ex.totalLockedMargin() + ex.protocolFeeAccumulator();
        assertEq(usdc.balanceOf(address(ex)), ex.treasury() / 1e12);
        assertGe(ex.treasury() + ex.totalQueued() + 1, liabilities);
    }
}
