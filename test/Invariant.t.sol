// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PerpsTest} from "./utils/PerpsTest.sol";
import {PerpetualFutures} from "../src/PerpetualFutures.sol";
import {MockUSDT} from "../src/MockUSDT.sol";
import {Oi} from "../src/InstrumentLib.sol";

contract PerpsHandler is Test {
    PerpetualFutures internal perps;
    MockPyth internal pyth;
    address internal owner;
    bytes32[3] internal feeds;
    uint256[3] internal initialPrices;
    uint256[3] internal prices;
    address[] public actors;
    uint256[] public positionIds;

    constructor(
        PerpetualFutures perps_,
        MockPyth pyth_,
        MockUSDT usdt,
        address owner_,
        bytes32[3] memory feeds_,
        uint256[3] memory prices_
    ) {
        perps = perps_;
        pyth = pyth_;
        owner = owner_;
        feeds = feeds_;
        initialPrices = prices_;
        prices = prices_;
        for (uint256 i; i < 3; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            usdt.mint(actor, 1e15);
            vm.prank(actor);
            usdt.approve(address(perps), type(uint256).max);
            actors.push(actor);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function open(uint256 actorSeed, uint256 marketSeed, bool isLong, uint256 margin, uint256 leverage) external {
        uint32 market = uint32(bound(marketSeed, 0, 2));
        margin = bound(margin, 1, 1_000) * 1e18;
        leverage = bound(leverage, 10, 1_000);
        refreshPrices();

        vm.prank(actors[bound(actorSeed, 0, actors.length - 1)]);
        positionIds.push(perps.openPosition(market, isLong, uint128(margin), uint32(leverage), new bytes[](0)));
    }

    function close(uint256 idSeed) external {
        if (positionIds.length == 0) return;
        uint256 id = positionIds[bound(idSeed, 0, positionIds.length - 1)];
        (address trader,,,,,,,,) = perps.positions(id);
        refreshPrices();

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(trader);
        perps.closePositions(ids, new bytes[](0));
    }

    function closeAll(uint256 actorSeed) external {
        address trader = actors[bound(actorSeed, 0, actors.length - 1)];
        refreshPrices();

        uint256[] memory ids = perps.openPositionIds(trader);
        vm.prank(trader);
        perps.closePositions(ids, new bytes[](0));
    }

    function liquidate(uint256 idSeed) external {
        if (positionIds.length == 0) return;
        refreshPrices();

        uint256[] memory ids = new uint256[](1);
        ids[0] = positionIds[bound(idSeed, 0, positionIds.length - 1)];
        perps.liquidateBatch(ids, new bytes[](0));
    }

    function movePrice(uint256 marketSeed, int256 bps) external {
        uint256 market = bound(marketSeed, 0, 2);
        uint256 moved = uint256(int256(prices[market]) * (10_000 + bound(bps, -500, 500)) / 10_000);
        uint256 floor = initialPrices[market] / 2;
        uint256 ceiling = initialPrices[market] * 2;
        prices[market] = moved < floor ? floor : moved > ceiling ? ceiling : moved;
        refreshPrices();
    }

    function harvest(uint256 maxEntries) external {
        perps.harvest(bound(maxEntries, 1, 10));
    }

    function refreshPrices() internal {
        skip(1);
        bytes[] memory update = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            int64 price = int64(uint64(prices[i]));
            update[i] = pyth.createPriceFeedUpdateData(
                feeds[i], price, 0, -8, price, 0, uint64(block.timestamp), uint64(block.timestamp - 1)
            );
        }
        pyth.updatePriceFeeds{value: pyth.getUpdateFee(update)}(update);
    }
}

contract InvariantTest is PerpsTest {
    PerpsHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new PerpsHandler(
            perps, pyth, usdt, owner, [BTC_FEED, ETH_FEED, BNB_FEED], [BTC_PRICE, ETH_PRICE, BNB_PRICE]
        );
        vm.deal(address(handler), 100 ether);
        targetContract(address(handler));
    }

    function invariant_TokensCoverPoolAndOpenMargin() public view {
        assertEq(usdt.balanceOf(address(perps)) * SCALE, perps.treasury() + perps.totalLockedMargin());
    }

    function invariant_QueuedBalancesAddUpToTotalDebt() public view {
        uint256 sum = queued(owner);
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += queued(handler.actors(i));
        }
        assertEq(perps.treasuryDebt(), sum);
    }

    function invariant_QueueEntriesCoverEveryQueuedBalance() public view {
        assertGe(queuedEntriesOf(owner), queued(owner));
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            assertGe(queuedEntriesOf(actor), queued(actor));
        }
    }

    function invariant_OpenPositionsMatchMarginAndOpenInterest() public view {
        uint256 locked;
        uint256[3] memory longs;
        uint256[3] memory shorts;
        for (uint256 id; id < perps.nextPositionId(); ++id) {
            (
                ,
                uint32 market,
                uint64 entry,
                uint128 collateral,
                uint128 debited,
                uint32 leverage,,
                bool isLong,
                bool isOpen
            ) = perps.positions(id);
            if (!isOpen) continue;
            locked += collateral - debited;
            uint256 size = uint256(collateral) * leverage * 1e8 / entry;
            if (isLong) longs[market] += size;
            else shorts[market] += size;
        }

        assertEq(perps.totalLockedMargin(), locked);
        for (uint32 market; market < 3; ++market) {
            Oi memory oi = openInterest(market);
            assertEq(oi.longSize, longs[market]);
            assertEq(oi.shortSize, shorts[market]);
        }
    }

    function queuedEntriesOf(address user) internal view returns (uint256 total) {
        for (uint256 id = perps.queueHead(); id < perps.queueTail(); ++id) {
            (address entryUser, uint256 amount) = perps.queue(id);
            if (entryUser == user) total += amount;
        }
    }
}
