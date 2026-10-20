// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {PerpetualFutures} from "../src/PerpetualFutures.sol";
import {Martingaler} from "../src/Martingaler.sol";
import {IPerpetualFutures} from "../src/interfaces/IPerpetualFutures.sol";
import {TraderStats} from "../src/TraderStatsLib.sol";
import {Config, InstrumentLib, Oi} from "../src/InstrumentLib.sol";
import {MockUSDT} from "../src/MockUSDT.sol";

contract MockToken is ERC20 {
    uint8 immutable dec;

    constructor(uint8 dec_) ERC20("Mock", "MOCK") {
        dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PerpetualFuturesTest is Test {
    bytes32 constant BTC = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant ETH = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    uint64 constant P8 = 1e8;
    uint256 constant WALLET = 100_000e6;

    MockPyth pyth;
    MockUSDT usdt;
    PerpetualFutures ex;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");
    bytes[] noUpdate;

    function setUp() public {
        vm.warp(1_700_000_000);
        pyth = new MockPyth(60, 1);
        usdt = new MockUSDT();
        ex = new PerpetualFutures(owner, address(pyth), address(usdt));
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

    function _instrument(bytes32 priceId) internal pure returns (Config memory) {
        return Config({
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

    function updateData(bytes32 id, int64 price, int32 expo) internal returns (bytes[] memory data) {
        vm.warp(block.timestamp + 1);
        data = new bytes[](1);
        data[0] = pyth.createPriceFeedUpdateData(id, price, 0, expo, price, 0, uint64(block.timestamp), 0);
    }

    function updateData(bytes32 id, uint256 price8) internal returns (bytes[] memory) {
        return updateData(id, int64(uint64(price8)), -8);
    }

    function setPrice(bytes32 id, uint256 price8) internal {
        pyth.updatePriceFeeds{value: 1}(updateData(id, price8));
    }

    function setRawPrice(bytes32 id, int64 price, int32 expo) internal {
        pyth.updatePriceFeeds{value: 1}(updateData(id, price, expo));
    }

    function fundHouse(uint256 amount) internal {
        usdt.mint(address(this), amount);
        usdt.approve(address(ex), amount);
        ex.fundHouse(amount);
    }

    function fundWallet(address who, uint256 amount) internal {
        usdt.mint(who, amount);
        vm.prank(who);
        usdt.approve(address(ex), type(uint256).max);
    }

    function open(address who, uint32 instrumentId, bool isLong, uint128 collateral, uint32 lev)
        internal
        returns (uint256)
    {
        vm.prank(who);
        return ex.openPosition(instrumentId, isLong, collateral, lev, noUpdate);
    }

    function close(address who, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(who);
        ex.closePositions(ids, noUpdate);
    }

    function liquidate(uint256 id) internal returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(liquidator);
        return ex.liquidateBatch(ids, noUpdate);
    }

    function oi(uint32 instrumentId) internal view returns (Oi memory o) {
        (, o) = ex.instruments(instrumentId);
    }

    function testOpenPullsCollateralFromWallet() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        (address posOwner,, uint64 entry, uint128 coll,, uint32 lev,, bool isLong, bool isOpen) = ex.positions(id);
        assertEq(posOwner, alice);
        assertEq(entry, 80_000 * P8);
        assertEq(coll, 1_000e18);
        assertEq(lev, 10);
        assertTrue(isLong && isOpen);
        assertEq(usdt.balanceOf(alice), WALLET - 1_000e6);
        assertEq(ex.totalLockedMargin(), 1_000e18);
        assertEq(usdt.balanceOf(address(ex)), 1_001_000e6);
        assertEq(oi(0).longSize, 10_000e18 * 1e8 / (80_000 * P8));
    }

    function testCollateralMustMatchTokenPrecision() public {
        vm.prank(alice);
        vm.expectRevert(IPerpetualFutures.CollateralPrecision.selector);
        ex.openPosition(0, true, 1_000e18 + 1, 10, noUpdate);
    }

    function testOpenLongCloseWithProfit() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        setPrice(BTC, 88_000 * P8);
        (int256 rawPnl, int256 pnl) = ex.previewPnl(id, 88_000 * P8);
        assertGt(rawPnl, 0);
        assertGt(pnl, 0);
        assertLt(pnl, rawPnl);

        uint256 houseBefore = ex.treasury();
        close(alice, id);
        (,,,,,,,, bool isOpen) = ex.positions(id);
        assertFalse(isOpen);
        uint256 fee = uint256(pnl) * 0.02e18 / 1e18;
        uint256 win = uint256(pnl) - fee;
        assertEq(usdt.balanceOf(alice), WALLET + win / 1e12);
        assertEq(ex.protocolFeeAccumulator(), fee);
        assertEq(ex.totalLockedMargin(), 0);
        assertEq(ex.treasury(), houseBefore - win + win % 1e12);
        assertEq(ex.getUserOpenPositionIds(alice).length, 0);
        assertEq(oi(0).longSize, 0);
    }

    function testOpenShortCloseWithLoss() public {
        uint256 id = open(alice, 0, false, 1_000e18, 5);
        setPrice(BTC, 84_000 * P8);
        (, int256 pnl) = ex.previewPnl(id, 84_000 * P8);
        assertEq(pnl, -250e18);
        close(alice, id);
        uint256 fee = 250e18 * 0.02e18 / 1e18;
        assertEq(usdt.balanceOf(alice), WALLET - 1_000e6 + 750e6);
        assertEq(ex.protocolFeeAccumulator(), fee);
        assertEq(ex.treasury(), 1_000_000e18 + 250e18);
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

    function testCloseSkipsForeignClosedAndMissingPositions() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(alice);
        ex.closePositions(new uint256[](0), noUpdate);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit IPerpetualFutures.PositionsClosed(bob, 0, 0, 0);
        ex.closePositions(ids, noUpdate);
        (,,,,,,,, bool isOpen) = ex.positions(id);
        assertTrue(isOpen);
        assertEq(usdt.balanceOf(bob), WALLET);

        close(alice, id);
        uint256 balance = usdt.balanceOf(alice);
        close(alice, id);
        assertEq(usdt.balanceOf(alice), balance);
    }

    function rejectConfig(Config memory config) internal {
        vm.prank(owner);
        vm.expectRevert(InstrumentLib.InvalidInstrumentConfig.selector);
        ex.addInstrument(config, 1e8, "BAD");
    }

    function testAddInstrumentRejectsBadConfig() public {
        Config memory c = _instrument(BTC);
        c.priceId = bytes32(0);
        rejectConfig(c);
        c = _instrument(BTC);
        c.liquidationBuffer = 1e18;
        rejectConfig(c);
        c = _instrument(BTC);
        c.maxLeverage = 0;
        rejectConfig(c);
        c = _instrument(BTC);
        c.maxNotional = 0;
        rejectConfig(c);
        c = _instrument(BTC);
        c.impactA = 0;
        rejectConfig(c);
        c = _instrument(BTC);
        c.impactC = 0;
        rejectConfig(c);
        c = _instrument(BTC);
        c.profitHaircut = 1e18;
        rejectConfig(c);

        vm.prank(owner);
        vm.expectRevert(InstrumentLib.InvalidSizeScale.selector);
        ex.addInstrument(_instrument(BTC), 0, "BAD");
        assertEq(ex.instrumentCount(), 2);
    }

    function testSettersRejectUnknownInstrument() public {
        vm.startPrank(owner);
        vm.expectRevert(InstrumentLib.InvalidInstrumentId.selector);
        ex.setRiskParams(7, 100, 1e24);
        vm.expectRevert(InstrumentLib.InvalidInstrumentId.selector);
        ex.setImpactConfig(7, 1e20, 1e18, 1e21, 0.05e18);
        vm.expectRevert(InstrumentLib.InvalidInstrumentId.selector);
        ex.setOiCaps(7, 1, 1);
        vm.stopPrank();
    }

    function testSettersRejectNonOwner() public {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(notOwner);
        ex.setRiskParams(0, 100, 1e24);
        vm.expectRevert(notOwner);
        ex.setImpactConfig(0, 1e20, 1e18, 1e21, 0.05e18);
        vm.expectRevert(notOwner);
        ex.setOiCaps(0, 1, 1);
        vm.expectRevert(notOwner);
        ex.setFeeRates(0, 0, 0);
        vm.expectRevert(notOwner);
        ex.setTradeMinimums(0, 0);
        vm.expectRevert(notOwner);
        ex.setMaxPriceAge(1);
        vm.expectRevert(notOwner);
        ex.setTradingPaused(true);
        vm.expectRevert(notOwner);
        ex.addInstrument(_instrument(BTC), 1e8, "BTC");
        vm.stopPrank();
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
        assertEq(oi(0).longSize, 10_000e18 * 1e8 / (80_000 * P8));
        uint256 liq = ex.liquidationPrice(id);
        setPrice(BTC, liq + 1);
        assertEq(liquidate(id), 0);

        setPrice(BTC, liq);
        assertEq(liquidate(id), 1);
        (,,,,,,,, bool isOpen) = ex.positions(id);
        assertFalse(isOpen);
        assertEq(usdt.balanceOf(alice), WALLET - 1_000e6);
        assertEq(ex.totalLockedMargin(), 0);
        uint256 fee = 1_000e18 * 0.02e18 / 1e18;
        assertEq(ex.protocolFeeAccumulator(), fee);
        assertEq(ex.treasury(), 1_000_000e18 + 1_000e18);
        assertEq(oi(0).longSize, 0);
        assertEq(ex.getUserOpenPositionIds(alice).length, 0);
    }

    function testLiquidateShort() public {
        uint256 id = open(alice, 0, false, 1_000e18, 10);
        assertEq(oi(0).shortSize, 10_000e18 * 1e8 / (80_000 * P8));
        uint256 liq = ex.liquidationPrice(id);
        setPrice(BTC, liq - 1);
        assertEq(liquidate(id), 0);

        setPrice(BTC, liq);
        assertEq(liquidate(id), 1);
        (,,,,,,,, bool isOpen) = ex.positions(id);
        assertFalse(isOpen);
        assertEq(usdt.balanceOf(alice), WALLET - 1_000e6);
        assertEq(ex.totalLockedMargin(), 0);
        assertEq(ex.protocolFeeAccumulator(), 1_000e18 * 0.02e18 / 1e18);
        assertEq(ex.treasury(), 1_000_000e18 + 1_000e18);
        assertEq(oi(0).shortSize, 0);
        assertEq(ex.getUserOpenPositionIds(alice).length, 0);
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

    function testPriceUpdateInTxKeepsExcessOnContract() public {
        bytes[] memory data = updateData(BTC, 90_000 * P8);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 id = ex.openPosition{value: 0.01 ether}(0, true, 1_000e18, 10, data);
        (,, uint64 entry,,,,,,) = ex.positions(id);
        assertEq(entry, 90_000 * P8);
        assertEq(alice.balance, balBefore - 0.01 ether);
        assertEq(address(ex).balance, 0.01 ether - 1);

        bytes[] memory next = updateData(BTC, 91_000 * P8);
        vm.prank(bob);
        ex.openPosition(0, true, 1_000e18, 10, next);
        assertEq(address(ex).balance, 0.01 ether - 2);

        vm.prank(alice);
        vm.expectRevert();
        ex.withdrawNative(alice, 1);
        vm.prank(owner);
        ex.withdrawNative(owner, 0.01 ether - 2);
        assertEq(owner.balance, 0.01 ether - 2);
        assertEq(address(ex).balance, 0);
    }

    function testInsufficientUpdateFeeReverts() public {
        bytes[] memory data = updateData(BTC, 90_000 * P8);
        vm.prank(alice);
        vm.expectRevert(IPerpetualFutures.InsufficientUpdateFee.selector);
        ex.openPosition{value: 0}(0, true, 1_000e18, 10, data);
    }

    function testStalePriceReverts() public {
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        vm.expectRevert(PythErrors.StalePrice.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);
    }

    function testPriceNormalizedAcrossExponents() public {
        setRawPrice(BTC, 80_000e5, -5);
        uint256 a = open(alice, 0, true, 1_000e18, 10);
        setRawPrice(BTC, 80_000e10, -10);
        uint256 b = open(bob, 0, true, 1_000e18, 10);
        (,, uint64 entryA,,,,,,) = ex.positions(a);
        (,, uint64 entryB,,,,,,) = ex.positions(b);
        assertEq(entryA, 80_000 * P8);
        assertEq(entryB, 80_000 * P8);
    }

    function testNonPositivePriceReverts() public {
        setRawPrice(BTC, 0, -8);
        vm.prank(alice);
        vm.expectRevert(InstrumentLib.InvalidPrice.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);

        setRawPrice(BTC, -80_000e8, -8);
        vm.prank(alice);
        vm.expectRevert(InstrumentLib.InvalidPrice.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);

        setRawPrice(BTC, 5, -10);
        vm.prank(alice);
        vm.expectRevert(InstrumentLib.InvalidPrice.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);
    }

    function testOpenParamChecks() public {
        vm.startPrank(alice);
        vm.expectRevert(InstrumentLib.TradeBelowMinimum.selector);
        ex.openPosition(0, true, 9e18, 10, noUpdate);
        vm.expectRevert(InstrumentLib.NotionalBelowMinimum.selector);
        ex.openPosition(0, true, 10e18, 10, noUpdate);
        vm.expectRevert(InstrumentLib.LeverageTooHigh.selector);
        ex.openPosition(0, true, 1_000e18, 1001, noUpdate);
        vm.expectRevert(InstrumentLib.LeverageTooLow.selector);
        ex.openPosition(0, true, 1_000e18, 0, noUpdate);
        vm.expectRevert(InstrumentLib.PositionTooLarge.selector);
        ex.openPosition(0, true, 10_000e18, 101, noUpdate);
        vm.expectRevert(InstrumentLib.InvalidInstrumentId.selector);
        ex.openPosition(7, true, 1_000e18, 10, noUpdate);
        vm.expectRevert();
        ex.openPosition(0, true, 100_001e18, 1, noUpdate);
        vm.stopPrank();
    }

    function testOiCap() public {
        vm.prank(owner);
        ex.setOiCaps(0, uint96(10_000e18 * 1e8 / (80_000 * P8)), type(uint96).max);
        open(alice, 0, true, 1_000e18, 10);
        vm.prank(bob);
        vm.expectRevert(InstrumentLib.OiCapExceeded.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);
        open(bob, 0, false, 1_000e18, 10);
    }

    function testTradingPauseBlocksOpenCloseAndLiquidate() public {
        uint256 id = open(alice, 0, true, 1_000e18, 10);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(owner);
        ex.setTradingPaused(true);

        vm.prank(alice);
        vm.expectRevert(IPerpetualFutures.TradingPaused.selector);
        ex.openPosition(0, true, 1_000e18, 10, noUpdate);
        vm.prank(alice);
        vm.expectRevert(IPerpetualFutures.TradingPaused.selector);
        ex.closePositions(ids, noUpdate);
        setPrice(BTC, ex.liquidationPrice(id));
        vm.prank(liquidator);
        vm.expectRevert(IPerpetualFutures.TradingPaused.selector);
        ex.liquidateBatch(ids, noUpdate);

        vm.prank(owner);
        ex.setTradingPaused(false);
        assertEq(liquidate(id), 1);
    }

    function testFundHouseZeroReverts() public {
        vm.expectRevert(IPerpetualFutures.ZeroAmount.selector);
        ex.fundHouse(0);
    }

    function testConstructorRejectsTokenAbove18Decimals() public {
        MockToken token = new MockToken(19);
        vm.expectRevert(IPerpetualFutures.UnsupportedCollateralDecimals.selector);
        new PerpetualFutures(owner, address(pyth), address(token));
    }

    function testFuzz18DecimalCollateralSettlesExactly(uint128 collateral, bool isLong) public {
        collateral = uint128(bound(collateral, 1e18, 10_000e18));
        MockToken token = new MockToken(18);
        ex = new PerpetualFutures(owner, address(pyth), address(token));
        assertEq(ex.collateralScale(), 1);
        vm.prank(owner);
        ex.addInstrument(_instrument(BTC), 1e8, "BTC");
        token.mint(address(this), 1_000_000e18);
        token.approve(address(ex), 1_000_000e18);
        ex.fundHouse(1_000_000e18);
        token.mint(alice, collateral);
        vm.prank(alice);
        token.approve(address(ex), collateral);

        uint256 id = open(alice, 0, isLong, collateral, 10);
        assertEq(token.balanceOf(alice), 0);
        assertEq(ex.totalLockedMargin(), collateral);
        setPrice(BTC, 84_000 * P8);
        (, int256 pnl) = ex.previewPnl(id, 84_000 * P8);
        close(alice, id);

        uint256 fee = (pnl > 0 ? uint256(pnl) : uint256(-pnl)) * 0.02e18 / 1e18;
        uint256 settled = pnl > 0 ? collateral + uint256(pnl) - fee : collateral - uint256(-pnl);
        assertEq(token.balanceOf(alice), settled);
        assertEq(ex.treasury(), 1_000_000e18 + collateral - settled);
        assertEq(ex.protocolFeeAccumulator(), fee);
        assertEq(ex.totalLockedMargin(), 0);
        assertEq(token.balanceOf(address(ex)), ex.treasury());
    }

    function bigWin(address who) internal returns (uint256 paid, uint256 queued) {
        uint256 id = open(who, 0, true, 40_000e18, 25);
        setPrice(BTC, 200_000 * P8);
        (, int256 pnl) = ex.previewPnl(id, 200_000 * P8);
        assertGt(uint256(pnl), 1_000_000e18);
        uint256 profit = uint256(pnl) - uint256(pnl) * 0.02e18 / 1e18;
        uint256 treasuryBefore = ex.treasury();
        paid = ex.queueLength() == 0 ? (treasuryBefore < profit ? treasuryBefore : profit) : 0;
        queued = profit - paid;
        uint256 nextId = ex.queueTail();
        if (queued != 0) {
            vm.expectEmit(address(ex));
            emit Martingaler.Enqueued(who, nextId, queued);
        }
        close(who, id);
        setPrice(BTC, 80_000 * P8);
    }

    function testProfitPaidPartiallyRestQueued() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        (uint256 paid, uint256 queued) = bigWin(alice);

        assertEq(paid, 1_000_000e18);
        assertGt(queued, 0);
        assertEq(usdt.balanceOf(alice), WALLET + paid / 1e12);
        assertEq(ex.treasury(), 0);
        assertEq(ex.queueLength(), 1);
        assertEq(ex.treasuryDebt(), queued);
        assertEq(ex.treasuryDebtOf(alice), queued);
        assertEq(ex.totalLockedMargin(), 0);
        (address user, uint256 amount) = ex.queue(0);
        assertEq(user, alice);
        assertEq(amount, queued);
        assertEq(ex.harvest(10), 0);
    }

    function testHarvestPaysFrontPartiallyThenFully() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        (uint256 paid, uint256 queued) = bigWin(alice);

        uint256 bobId = open(bob, 0, false, 50_000e18, 2);
        setPrice(BTC, 160_000 * P8);
        close(bob, bobId);
        assertEq(ex.treasury(), 50_000e18);
        assertLt(50_000e18, queued);
        uint256 remaining = queued - 50_000e18;

        vm.expectEmit(address(ex));
        emit Martingaler.QueuePaid(alice, 0, 50_000e18, remaining);
        assertEq(ex.harvest(10), 0);
        assertEq(usdt.balanceOf(alice), WALLET + paid / 1e12 + 50_000e6);
        assertEq(ex.treasury(), 0);
        assertEq(ex.queueLength(), 1);
        assertEq(ex.treasuryDebt(), remaining);
        assertEq(ex.treasuryDebtOf(alice), remaining);
        (, uint256 amount) = ex.queue(0);
        assertEq(amount, remaining);

        fundHouse(remaining / 1e12 + 1e6);
        uint256 treasuryBefore = ex.treasury();
        vm.expectEmit(address(ex));
        emit Martingaler.QueuePaid(alice, 0, remaining, 0);
        assertEq(ex.harvest(10), 1);
        assertEq(usdt.balanceOf(alice), WALLET + paid / 1e12 + 50_000e6 + remaining / 1e12);
        assertEq(ex.treasuryDebtOf(alice), 0);
        assertEq(ex.queueLength(), 0);
        assertEq(ex.treasuryDebt(), 0);
        assertEq(ex.treasury(), treasuryBefore - remaining + remaining % 1e12);
    }

    function testWinAppendsWhileQueueExistsUntilHarvest() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        (uint256 paid, uint256 queued) = bigWin(alice);

        uint256 bobId = open(bob, 0, true, 1_000e18, 10);
        setPrice(BTC, 88_000 * P8);
        (, int256 bobPnl) = ex.previewPnl(bobId, 88_000 * P8);
        close(bob, bobId);
        setPrice(BTC, 80_000 * P8);
        uint256 bobProfit = uint256(bobPnl) - uint256(bobPnl) * 0.02e18 / 1e18;
        assertEq(usdt.balanceOf(bob), WALLET);
        assertEq(ex.queueLength(), 2);
        assertEq(ex.treasuryDebtOf(bob), bobProfit);
        assertEq(ex.treasuryDebt(), queued + bobProfit);

        fundHouse(2_000_000e6);
        uint256 bobSecond = open(bob, 0, true, 1_000e18, 10);
        setPrice(BTC, 88_000 * P8);
        close(bob, bobSecond);
        assertEq(ex.queueLength(), 3);
        assertEq(usdt.balanceOf(alice), WALLET + paid / 1e12);
        assertEq(ex.treasuryDebtOf(alice), queued);

        assertEq(ex.harvest(10), 3);
        assertEq(ex.queueLength(), 0);
        assertEq(usdt.balanceOf(alice), WALLET + paid / 1e12 + queued / 1e12);
        assertEq(ex.treasuryDebtOf(alice), 0);
        assertEq(usdt.balanceOf(bob), WALLET + 2 * (bobProfit / 1e12));
        assertEq(ex.treasuryDebtOf(bob), 0);
    }

    function testHarvestStopsAtMaxEntries() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        bigWin(alice);
        bigWin(bob);
        assertEq(ex.queueLength(), 2);
        fundHouse(5_000_000e6);
        assertEq(ex.harvest(1), 1);
        assertEq(ex.queueLength(), 1);
        assertEq(ex.treasuryDebtOf(alice), 0);
        assertEq(ex.harvest(1), 1);
        assertEq(ex.queueLength(), 0);
        assertEq(ex.treasuryDebtOf(bob), 0);
    }

    function testProtocolFeesQueueWhenTreasuryShort() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        bigWin(alice);
        uint256 id = open(bob, 0, true, 1_000e18, 10);
        setPrice(BTC, 70_000 * P8);
        close(bob, id);
        uint256 fees = ex.protocolFeeAccumulator();
        assertGt(fees, 0);
        vm.prank(owner);
        ex.claimProtocolFees();
        assertEq(usdt.balanceOf(owner), 0);
        assertEq(ex.treasuryDebtOf(owner), fees);
        assertEq(ex.queueLength(), 2);
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
        assertEq(usdt.balanceOf(owner), fees / 1e12);
        assertEq(ex.protocolFeeAccumulator(), 0);
    }

    function testCloseBatchMixed() public {
        uint256 a = open(alice, 0, true, 1_000e18, 10);
        uint256 b = open(alice, 1, false, 2_000e18, 3);
        uint256 c = open(bob, 0, true, 1_000e18, 10);
        setPrice(BTC, 82_000 * P8);
        setPrice(ETH, 4_100 * P8);
        (, int256 pnlA) = ex.previewPnl(a, 82_000 * P8);
        (, int256 pnlB) = ex.previewPnl(b, 4_100 * P8);
        assertGt(pnlA, 0);
        assertLt(pnlB, 0);
        uint256 feeA = uint256(pnlA) * 0.02e18 / 1e18;
        uint256 feeB = uint256(-pnlB) * 0.02e18 / 1e18;
        uint256 marginReturned = 1_000e18 + 2_000e18 - uint256(-pnlB);
        uint256 owed = uint256(pnlA) - feeA;
        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;

        vm.expectEmit(address(ex));
        emit IPerpetualFutures.PositionsClosed(alice, marginReturned + owed, 0, feeA + feeB);
        vm.prank(alice);
        ex.closePositions(ids, noUpdate);

        (,,,,,,,, bool cOpen) = ex.positions(c);
        assertTrue(cOpen);
        assertEq(ex.getUserOpenPositionIds(alice).length, 0);
        assertEq(ex.getUserOpenPositionIds(bob).length, 1);
        assertEq(usdt.balanceOf(alice), WALLET - 3_000e6 + marginReturned / 1e12 + owed / 1e12);
        assertEq(ex.protocolFeeAccumulator(), feeA + feeB);
        assertEq(ex.treasury(), 1_000_000e18 + uint256(-pnlB) - owed + owed % 1e12 + marginReturned % 1e12);
        assertEq(ex.totalLockedMargin(), 1_000e18);
        assertEq(oi(1).shortSize, 0);
        assertSolvent();
    }

    function testCloseBatchNetsLossAgainstWinBeforeQueue() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        (, uint256 aliceQueued) = bigWin(alice);
        assertEq(ex.queueLength(), 1);

        uint256 a = open(bob, 0, true, 1_000e18, 10);
        uint256 b = open(bob, 1, false, 2_000e18, 3);
        setPrice(BTC, 205_000 * P8);
        setPrice(ETH, 4_100 * P8);
        (, int256 pnlA) = ex.previewPnl(a, 205_000 * P8);
        (, int256 pnlB) = ex.previewPnl(b, 4_100 * P8);
        assertGt(pnlA, 0);
        assertLt(pnlB, 0);
        uint256 feeA = uint256(pnlA) * 0.02e18 / 1e18;
        uint256 feeB = uint256(-pnlB) * 0.02e18 / 1e18;
        uint256 losses = uint256(-pnlB);
        uint256 owed = uint256(pnlA) - feeA;
        assertGt(owed, losses);
        uint256 marginReturned = 1_000e18 + 2_000e18 - losses;
        uint256 direct = marginReturned + losses;
        uint256 treasuryBefore = ex.treasury();
        uint256 feesBefore = ex.protocolFeeAccumulator();
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;

        vm.expectEmit(address(ex));
        emit Martingaler.Enqueued(bob, ex.queueTail(), owed - losses);
        vm.expectEmit(address(ex));
        emit IPerpetualFutures.PositionsClosed(bob, direct, owed - losses, feeA + feeB);
        vm.prank(bob);
        ex.closePositions(ids, noUpdate);

        assertEq(usdt.balanceOf(bob), WALLET - 3_000e6 + direct / 1e12);
        assertEq(ex.queueLength(), 2);
        assertEq(ex.treasuryDebtOf(bob), owed - losses);
        assertEq(ex.treasuryDebt(), aliceQueued + owed - losses);
        assertEq(ex.treasury(), treasuryBefore + direct % 1e12);
        assertEq(ex.protocolFeeAccumulator(), feesBefore + feeA + feeB);
        assertSolvent();
    }

    function stats(address who) internal view returns (TraderStats memory s) {
        (s.volume, s.profit, s.loss, s.liquidated, s.fees, s.positions, s.liquidations) = ex.traderStats(who);
    }

    function totals() internal view returns (TraderStats memory s) {
        (s.volume, s.profit, s.loss, s.liquidated, s.fees, s.positions, s.liquidations) = ex.totalStats();
    }

    function assertStats(TraderStats memory actual, TraderStats memory expected) internal pure {
        assertEq(actual.volume, expected.volume, "volume");
        assertEq(actual.profit, expected.profit, "profit");
        assertEq(actual.loss, expected.loss, "loss");
        assertEq(actual.liquidated, expected.liquidated, "liquidated");
        assertEq(actual.fees, expected.fees, "fees");
        assertEq(actual.positions, expected.positions, "positions");
        assertEq(actual.liquidations, expected.liquidations, "liquidations");
    }

    function testTraderStatsTrackOpenCloseAndLiquidation() public {
        uint256 win = open(alice, 0, true, 1_000e18, 10);
        setPrice(BTC, 88_000 * P8);
        (, int256 pnlWin) = ex.previewPnl(win, 88_000 * P8);
        close(alice, win);
        setPrice(BTC, 80_000 * P8);

        uint256 lose = open(alice, 1, false, 2_000e18, 3);
        setPrice(ETH, 4_100 * P8);
        (, int256 pnlLose) = ex.previewPnl(lose, 4_100 * P8);
        close(alice, lose);

        uint256 liq = open(alice, 0, true, 1_000e18, 10);
        setPrice(BTC, ex.liquidationPrice(liq));
        assertEq(liquidate(liq), 1);
        setPrice(BTC, 80_000 * P8);

        open(bob, 0, false, 500e18, 20);

        uint256 fees = uint256(pnlWin) * 0.02e18 / 1e18 + uint256(-pnlLose) * 0.02e18 / 1e18 + 1_000e18 * 0.02e18 / 1e18;
        TraderStats memory aliceStats = TraderStats({
            volume: 10_000e18 + 6_000e18 + 10_000e18,
            profit: uint128(uint256(pnlWin)),
            loss: uint128(uint256(-pnlLose)),
            liquidated: 1_000e18,
            fees: uint128(fees),
            positions: 3,
            liquidations: 1
        });
        TraderStats memory bobStats =
            TraderStats({volume: 10_000e18, profit: 0, loss: 0, liquidated: 0, fees: 0, positions: 1, liquidations: 0});
        assertStats(stats(alice), aliceStats);
        assertStats(stats(bob), bobStats);

        TraderStats memory total = aliceStats;
        total.volume += bobStats.volume;
        total.positions += bobStats.positions;
        assertStats(totals(), total);
        assertEq(stats(liquidator).volume, 0);
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

    function testFuzzLiquidationBoundary(uint64 entry, uint32 lev) public {
        entry = uint64(bound(entry, 1 * P8, 1_000_000 * P8));
        lev = uint32(bound(lev, 2, 1000));
        setPrice(BTC, entry);
        uint256 longId = open(alice, 0, true, 1_000e18, lev);
        uint256 shortId = open(bob, 0, false, 1_000e18, lev);
        uint256 longLiq = ex.liquidationPrice(longId);
        uint256 shortLiq = ex.liquidationPrice(shortId);
        assertLt(longLiq, entry);
        assertGt(shortLiq, entry);

        setPrice(BTC, longLiq + 1);
        assertEq(liquidate(longId), 0);
        setPrice(BTC, shortLiq - 1);
        assertEq(liquidate(shortId), 0);
        setPrice(BTC, longLiq);
        assertEq(liquidate(longId), 1);
        setPrice(BTC, shortLiq);
        assertEq(liquidate(shortId), 1);
        assertEq(ex.treasury(), 1_000_000e18 + 2_000e18);
        assertSolvent();
    }

    function assertSolvent() internal view {
        assertEq(usdt.balanceOf(address(ex)) * 1e12, ex.treasury() + ex.totalLockedMargin());
        assertEq(ex.treasuryDebt(), ex.treasuryDebtOf(alice) + ex.treasuryDebtOf(bob));
    }

    function testOpenDebitsTreasuryDebtBeforeWallet() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        (, uint256 queued) = bigWin(alice);
        uint256 collateral = 1_000e18;
        assertGt(queued, collateral);
        uint256 walletBefore = usdt.balanceOf(alice);
        uint256 lockedBefore = ex.totalLockedMargin();

        vm.expectEmit(address(ex));
        emit Martingaler.Debited(alice, collateral);
        uint256 id = open(alice, 0, true, uint128(collateral), 10);
        (,,,, uint128 debited,,,,) = ex.positions(id);
        assertEq(debited, collateral);
        assertEq(usdt.balanceOf(alice), walletBefore);
        assertEq(ex.totalLockedMargin(), lockedBefore);
        assertEq(ex.treasuryDebtOf(alice), queued - collateral);
        assertEq(ex.treasuryDebt(), queued - collateral);
        assertSolvent();
    }

    function testHarvestSkipsDebitedPartOfEntry() public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        (uint256 paid, uint256 queued) = bigWin(alice);
        uint256 collateral = 1_000e18;
        uint256 id = open(alice, 0, true, uint128(collateral), 10);
        setPrice(BTC, ex.liquidationPrice(id));
        assertEq(liquidate(id), 1);
        assertEq(ex.treasury(), 0);
        assertEq(ex.totalLockedMargin(), 0);
        assertEq(ex.treasuryDebtOf(alice), queued - collateral);

        fundHouse(queued / 1e12 + 1e6);
        uint256 treasuryBefore = ex.treasury();
        assertEq(ex.harvest(10), 1);
        assertEq(ex.queueLength(), 0);
        assertEq(ex.treasuryDebt(), 0);
        assertEq(ex.treasuryDebtOf(alice), 0);
        assertEq(usdt.balanceOf(alice), WALLET + paid / 1e12 + (queued - collateral) / 1e12);
        assertEq(ex.treasury(), treasuryBefore - (queued - collateral) + (queued - collateral) % 1e12);
        assertSolvent();
    }

    function openWithPartialDebit(address who) internal returns (uint256 id, uint256 debited) {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        bigWin(alice);
        uint256 first = open(who, 0, true, 500e18, 10);
        setPrice(BTC, 88_000 * P8);
        close(who, first);
        setPrice(BTC, 80_000 * P8);
        uint256 debt = ex.treasuryDebtOf(who);
        assertGt(debt, 0);
        assertLt(debt, 1_000e18);

        vm.expectEmit(address(ex));
        emit Martingaler.Debited(who, debt - debt % 1e12);
        id = open(who, 0, true, 1_000e18, 10);
        (,,,, uint128 d,,,,) = ex.positions(id);
        debited = d;
        assertEq(debited, debt - debt % 1e12);
        assertEq(ex.treasuryDebtOf(who), debt - debited);
        assertEq(usdt.balanceOf(who), WALLET - (1_000e18 - debited) / 1e12);
        assertEq(ex.totalLockedMargin(), 1_000e18 - debited);
    }

    function testLossBurnsDebitBeforeCash() public {
        (uint256 id, uint256 debited) = openWithPartialDebit(bob);
        uint256 debtBefore = ex.treasuryDebtOf(bob);
        uint256 treasuryBefore = ex.treasury();

        setPrice(BTC, 79_000 * P8);
        (, int256 pnl) = ex.previewPnl(id, 79_000 * P8);
        uint256 loss = uint256(-pnl);
        assertLt(loss, debited);
        close(bob, id);

        assertEq(usdt.balanceOf(bob), WALLET);
        assertEq(ex.treasury(), treasuryBefore);
        assertEq(ex.treasuryDebtOf(bob), debtBefore + debited - loss);
        assertEq(ex.totalLockedMargin(), 0);
        assertSolvent();
    }

    function testLossAboveDebitBurnsDebitThenCash() public {
        (uint256 id, uint256 debited) = openWithPartialDebit(bob);
        uint256 cash = 1_000e18 - debited;
        uint256 debtBefore = ex.treasuryDebtOf(bob);
        uint256 treasuryBefore = ex.treasury();
        uint256 queueBefore = ex.queueLength();
        uint256 feesBefore = ex.protocolFeeAccumulator();

        setPrice(BTC, 74_000 * P8);
        (, int256 pnl) = ex.previewPnl(id, 74_000 * P8);
        uint256 loss = uint256(-pnl);
        assertGt(loss, debited);
        assertLt(loss, 1_000e18);
        uint256 cashLoss = loss - debited;
        uint256 fee = loss * 0.02e18 / 1e18;

        vm.expectEmit(address(ex));
        emit IPerpetualFutures.PositionsClosed(bob, cash - cashLoss, 0, fee);
        close(bob, id);

        assertEq(usdt.balanceOf(bob), WALLET - cashLoss / 1e12);
        assertEq(ex.treasury(), treasuryBefore + cashLoss);
        assertEq(ex.treasuryDebtOf(bob), debtBefore);
        assertEq(ex.queueLength(), queueBefore);
        assertEq(ex.protocolFeeAccumulator(), feesBefore + fee);
        assertEq(ex.totalLockedMargin(), 0);
        assertSolvent();
    }

    function testProfitWithDebitReturnsCashAndQueuesRest() public {
        (uint256 id, uint256 debited) = openWithPartialDebit(bob);
        uint256 cash = 1_000e18 - debited;
        uint256 debtBefore = ex.treasuryDebtOf(bob);
        uint256 treasuryBefore = ex.treasury();
        uint256 queueBefore = ex.queueLength();
        uint256 feesBefore = ex.protocolFeeAccumulator();

        setPrice(BTC, 84_000 * P8);
        (, int256 pnl) = ex.previewPnl(id, 84_000 * P8);
        assertGt(pnl, 0);
        uint256 fee = uint256(pnl) * 0.02e18 / 1e18;
        uint256 owed = debited + uint256(pnl) - fee;
        uint256 nextId = ex.queueTail();

        vm.expectEmit(address(ex));
        emit Martingaler.Enqueued(bob, nextId, owed);
        vm.expectEmit(address(ex));
        emit IPerpetualFutures.PositionsClosed(bob, cash, owed, fee);
        close(bob, id);

        assertEq(usdt.balanceOf(bob), WALLET);
        assertEq(ex.treasury(), treasuryBefore);
        assertEq(ex.treasuryDebtOf(bob), debtBefore + owed);
        assertEq(ex.queueLength(), queueBefore + 1);
        (address user, uint256 amount) = ex.queue(nextId);
        assertEq(user, bob);
        assertEq(amount, owed);
        assertEq(ex.protocolFeeAccumulator(), feesBefore + fee);
        assertEq(ex.totalLockedMargin(), 0);
        assertSolvent();
    }

    function testSolvencyInvariantWithDebit(uint8 n, uint256 seed) public {
        vm.prank(owner);
        ex.setTradeMinimums(10e18, 10e18);
        bigWin(alice);
        n = uint8(bound(n, 1, 24));
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = r % 2 == 0 ? alice : bob;
            uint32 instrumentId = uint32((r >> 4) % 2);
            uint64 base = instrumentId == 0 ? 80_000 * P8 : 4_000 * P8;
            setPrice(instrumentId == 0 ? BTC : ETH, uint64(base * (90 + (r >> 8) % 21) / 100));
            uint32 lev = uint32(1 + (r >> 16) % 20);
            vm.prank(who);
            try ex.openPosition(instrumentId, (r >> 24) % 2 == 0, 1_000e18, lev, noUpdate) {} catch {}
            uint256[] memory ids = ex.getUserOpenPositionIds(who);
            if (ids.length != 0 && (r >> 32) % 3 == 0) {
                uint256[] memory one = new uint256[](1);
                one[0] = ids[0];
                vm.prank(who);
                ex.closePositions(one, noUpdate);
            }
            if (ids.length != 0 && (r >> 40) % 4 == 0) liquidate(ids[0]);
            if ((r >> 48) % 5 == 0) fundHouse(uint256(1 + (r >> 56) % 50_000) * 1e6);
            if ((r >> 72) % 3 == 0) ex.harvest(3);
        }
        assertSolvent();
    }
}
