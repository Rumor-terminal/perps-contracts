// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PerpetualFutures} from "../../src/PerpetualFutures.sol";
import {MockUSDT} from "../../src/MockUSDT.sol";
import {Config, Oi} from "../../src/InstrumentLib.sol";
import {Position} from "../../src/PositionLib.sol";

abstract contract PerpsTest is Test {
    bytes32 internal constant BTC_FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant ETH_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant BNB_FEED = 0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f;

    uint32 internal constant BTC = 0;
    uint32 internal constant ETH = 1;
    uint32 internal constant BNB = 2;

    uint256 internal constant BTC_PRICE = 100_000e8;
    uint256 internal constant ETH_PRICE = 4_000e8;
    uint256 internal constant BNB_PRICE = 600e8;

    uint256 internal constant SCALE = 1e12;
    uint256 internal constant MAX_PRICE_AGE = 5;

    MockPyth internal pyth;
    MockUSDT internal usdt;
    PerpetualFutures internal perps;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal loser = makeAddr("loser");

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        vm.deal(address(this), 100 ether);

        pyth = new MockPyth(60, 1);
        usdt = new MockUSDT();
        address implementation = address(new PerpetualFutures());
        perps = PerpetualFutures(
            payable(new ERC1967Proxy(
                    implementation, abi.encodeCall(PerpetualFutures.initialize, (owner, address(pyth), address(usdt)))
                ))
        );
        vm.deal(address(perps), 1 ether);

        vm.startPrank(owner);
        perps.setTradeMinimums(1e18, 10e18);
        perps.setMaxPriceAge(MAX_PRICE_AGE);
        perps.addInstrument(launchConfig(BTC_FEED, 814.598e18), "BTC");
        perps.addInstrument(launchConfig(ETH_FEED, 483.979e18), "ETH");
        perps.addInstrument(launchConfig(BNB_FEED, 183.94e18), "BNB");
        vm.stopPrank();

        setPrice(BTC, BTC_PRICE);
        setPrice(ETH, ETH_PRICE);
        setPrice(BNB, BNB_PRICE);

        fund(alice);
        fund(bob);
        fund(carol);
        fund(loser);
    }

    function launchConfig(bytes32 feedId, uint256 marketFactor) internal pure returns (Config memory) {
        return Config({
            priceId: feedId,
            maxLeverage: 1000,
            maxNotional: 1_000_000e18,
            liquidationBuffer: 0.0005e18,
            impactA: 15_000e18,
            impactB: marketFactor,
            impactC: 0.1e18,
            profitHaircut: 0.1e18
        });
    }

    function fund(address trader) internal {
        usdt.mint(trader, 10_000_000e6);
        vm.prank(trader);
        usdt.approve(address(perps), type(uint256).max);
    }

    function feed(uint32 market) internal pure returns (bytes32) {
        return market == BTC ? BTC_FEED : market == ETH ? ETH_FEED : BNB_FEED;
    }

    function priceUpdate(uint32 market, int64 price, int32 expo) internal view returns (bytes[] memory update) {
        update = new bytes[](1);
        update[0] = pyth.createPriceFeedUpdateData(
            feed(market), price, 0, expo, price, 0, uint64(block.timestamp), uint64(block.timestamp - 1)
        );
    }

    function setPrice(uint32 market, int64 price, int32 expo) internal {
        skip(1);
        bytes[] memory update = priceUpdate(market, price, expo);
        pyth.updatePriceFeeds{value: pyth.getUpdateFee(update)}(update);
    }

    function setPrice(uint32 market, uint256 price) internal {
        setPrice(market, int64(uint64(price)), -8);
    }

    function currentPrice(uint32 market) internal view returns (uint256) {
        return uint256(uint64(pyth.getPriceUnsafe(feed(market)).price));
    }

    function movedPrice(uint256 price, int256 bps) internal pure returns (uint256) {
        return uint256(int256(price) * (10_000 + bps) / 10_000);
    }

    function open(address trader, uint32 market, bool isLong, uint256 margin, uint256 leverage)
        internal
        returns (uint256)
    {
        vm.prank(trader);
        return perps.openPosition(market, isLong, uint128(margin), uint32(leverage), new bytes[](0));
    }

    function close(address trader, uint256 id) internal {
        closeAll(trader, list(id));
    }

    function closeAll(address trader, uint256[] memory ids) internal {
        vm.prank(trader);
        perps.closePositions(ids, new bytes[](0));
    }

    function liquidate(uint256 id) internal {
        liquidateAll(list(id));
    }

    function liquidateAll(uint256[] memory ids) internal {
        vm.prank(keeper);
        perps.liquidateBatch(ids, new bytes[](0));
    }

    function lose(address trader, uint256 amount) internal {
        uint256 price = currentPrice(BNB);
        setPrice(BNB, price);
        uint256 id = open(trader, BNB, false, amount, 10);
        setPrice(BNB, price * 11 / 10);
        close(trader, id);
        setPrice(BNB, price);
    }

    function lose(uint256 amount) internal {
        lose(loser, amount);
    }

    function winBtc(address trader, uint256 margin, uint256 leverage, int256 bps) internal returns (uint256 net) {
        uint256 price = currentPrice(BTC);
        setPrice(BTC, price);
        uint256 id = open(trader, BTC, true, margin, leverage);
        uint256 mark = movedPrice(price, bps);
        setPrice(BTC, mark);
        net = netProfit(id, mark);
        close(trader, id);
        setPrice(BTC, price);
    }

    function winBtc(address trader) internal returns (uint256) {
        return winBtc(trader, 100e18, 100, 200);
    }

    function netProfit(uint256 id, uint256 mark) internal view returns (uint256) {
        (, int256 pnl) = perps.previewPnl(id, mark);
        uint256 profit = uint256(pnl);
        return profit - profit * perps.winFeeRate() / 1e18;
    }

    function wallet(address trader) internal view returns (uint256) {
        return usdt.balanceOf(trader) * SCALE;
    }

    function pool() internal view returns (uint256) {
        return perps.treasury();
    }

    function queued(address trader) internal view returns (uint256) {
        return perps.treasuryDebtOf(trader);
    }

    function position(uint256 id) internal view returns (Position memory p) {
        (p.owner, p.instrumentId, p.entryPrice, p.collateral, p.debited, p.leverage, p.openedAt, p.isLong, p.isOpen) =
            perps.positions(id);
    }

    function openInterest(uint32 market) internal view returns (Oi memory oi) {
        (, oi) = perps.instruments(market);
    }

    function list(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function list(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function list(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
    }
}
