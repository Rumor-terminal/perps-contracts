// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

library QueueLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_MERGE = 64;

    struct Node {
        address user;
        uint48 next;
        uint48 prev;
        uint256 amount;
    }

    struct Settlement {
        uint256 marginReturned;
        uint256 paidNow;
        uint256 queued;
        uint256 toSideBucket;
        uint256 stakerFee;
        uint256 devFee;
    }

    struct QueueState {
        mapping(uint256 => Node) nodes;
        uint256 head;
        uint256 nextId;
        uint256 totalQueued;
        mapping(address => uint256) userQueuedTotal;
        mapping(address => uint256) userQueueHead;
        mapping(address => uint256) userQueueTail;
    }

    error QueueIdOverflow();
    error InvalidCompactionRange();

    event Enqueued(address indexed user, uint256 indexed id, uint256 amount);
    event DebtConsumed(address indexed user, uint256 amount);
    event Harvested(address indexed user, uint256 amount, uint256 remaining);
    event DebtNodeMerged(address indexed user, uint256 indexed fromId, uint256 indexed intoId, uint256 amount);
    event DebtCompacted(address indexed user, uint256 indexed firstId, uint256 indexed intoId, uint256 count, uint256 amount);

    function enqueue(QueueState storage q, address user, uint256 amount) internal {
        _enqueue(q, user, amount);
    }

    function consume(QueueState storage q, address user, uint256 amount) internal {
        uint256 id = q.userQueueTail[user];
        uint256 total = q.totalQueued;
        uint256 userTotal = q.userQueuedTotal[user];
        uint256 remaining = amount;
        while (remaining != 0 && id != 0) {
            Node storage n = q.nodes[id];
            uint256 prev = n.prev;
            uint256 nodeAmount = n.amount;
            if (nodeAmount > remaining) {
                n.amount = nodeAmount - remaining;
                total -= remaining;
                userTotal -= remaining;
                remaining = 0;
            } else {
                remaining -= nodeAmount;
                total -= nodeAmount;
                userTotal -= nodeAmount;
                n.amount = 0;
                _unlink(q, id, user);
            }
            id = prev;
        }
        q.totalQueued = total;
        q.userQueuedTotal[user] = userTotal;
        if (total == 0) q.head = q.nextId;
        emit DebtConsumed(user, amount);
    }

    function harvest(
        QueueState storage q,
        uint256 maxIterations,
        uint256 available,
        mapping(address => uint256) storage balances,
        uint256 totalBalances
    ) internal returns (uint256 paid, uint256 newTotalBalances) {
        uint256 id = q.head;
        uint256 nextId = q.nextId;
        uint256 iterations;
        while (id < nextId && available != 0 && iterations < maxIterations) {
            (uint256 pay, bool settled) = _payNode(q, balances, id, available);
            if (settled) ++id;
            available -= pay;
            paid += pay;
            ++iterations;
        }
        uint256 total = q.totalQueued - paid;
        q.head = total == 0 ? nextId : id;
        q.totalQueued = total;
        newTotalBalances = totalBalances + paid;
    }

    function compactAdjacent(QueueState storage q, address user, uint256 startId, uint256 maxMerges)
        internal
        returns (uint256 count, uint256 amount, uint256 intoId)
    {
        if (user == address(0)) return (0, 0, 0);
        if (maxMerges == 0 || maxMerges > MAX_MERGE) maxMerges = MAX_MERGE;
        intoId = startId != 0 ? startId : q.userQueueHead[user];
        if (intoId == 0) return (0, 0, 0);
        Node storage into = q.nodes[intoId];
        if (into.user != user || into.amount == 0) return (0, 0, 0);
        uint256 nextId = q.nextId;
        uint256 scanned;
        for (uint256 id = intoId + 1; id < nextId && scanned < maxMerges; ++id) {
            ++scanned;
            Node storage n = q.nodes[id];
            uint256 nodeAmount = n.amount;
            if (nodeAmount == 0) continue;
            if (n.user != user) break;
            into.amount += nodeAmount;
            n.amount = 0;
            ++count;
            amount += nodeAmount;
            _unlink(q, id, user);
            _clearLinks(n);
            emit DebtNodeMerged(user, id, intoId, nodeAmount);
        }
        if (count == 0) return (0, 0, 0);
        emit DebtCompacted(user, intoId, intoId, count, amount);
    }

    function compactAdjacentRange(QueueState storage q, address user, uint256 fromId, uint256 toId, uint256 maxMerges)
        internal
        returns (uint256 count, uint256 amount, uint256 intoId)
    {
        if (user == address(0) || fromId == 0 || toId <= fromId || toId >= q.nextId) revert InvalidCompactionRange();
        if (maxMerges == 0 || maxMerges > MAX_MERGE) maxMerges = MAX_MERGE;
        if (toId - fromId > maxMerges) revert InvalidCompactionRange();
        Node storage into = q.nodes[fromId];
        if (into.user != user || into.amount == 0) revert InvalidCompactionRange();
        for (uint256 id = fromId + 1; id <= toId; ++id) {
            Node storage n = q.nodes[id];
            uint256 nodeAmount = n.amount;
            if (nodeAmount == 0) continue;
            if (n.user != user) revert InvalidCompactionRange();
            into.amount += nodeAmount;
            ++count;
            amount += nodeAmount;
            n.amount = 0;
            _unlink(q, id, user);
            _clearLinks(n);
            emit DebtNodeMerged(user, id, fromId, nodeAmount);
        }
        if (count == 0) return (0, 0, 0);
        intoId = fromId;
        emit DebtCompacted(user, fromId, fromId, count, amount);
    }

    function compactDust(QueueState storage q, address user, uint256 startId, uint256 maxMerges, uint256 dustThreshold)
        internal
        returns (uint256 count, uint256 amount, uint256 intoId)
    {
        if (user == address(0) || dustThreshold == 0) return (0, 0, 0);
        if (maxMerges == 0 || maxMerges > MAX_MERGE) maxMerges = MAX_MERGE;
        uint256 firstId = startId != 0 ? startId : q.userQueueHead[user];
        if (firstId == 0) return (0, 0, 0);
        Node storage first = q.nodes[firstId];
        if (first.user != user || first.amount == 0 || first.amount >= dustThreshold) return (0, 0, 0);

        (count, amount, intoId) = _scanDust(q, user, firstId, maxMerges, dustThreshold);
        if (count == 0 || intoId == 0 || amount == 0) return (0, 0, 0);
        _mergeChain(q, user, firstId, count, 0);
        q.nodes[intoId].amount += amount;
        emit DebtCompacted(user, firstId, intoId, count, amount);
    }

    function compactDustRange(
        QueueState storage q,
        address user,
        uint256 fromId,
        uint256 intoId,
        uint256 maxMerges,
        uint256 dustThreshold
    ) internal returns (uint256 count, uint256 amount, uint256 resultId) {
        if (user == address(0) || dustThreshold == 0 || fromId == 0 || intoId == 0 || fromId == intoId) {
            revert InvalidCompactionRange();
        }
        if (maxMerges == 0 || maxMerges > MAX_MERGE) maxMerges = MAX_MERGE;

        uint256 id = fromId;
        while (id != intoId && count < maxMerges) {
            Node storage n = q.nodes[id];
            uint256 nodeAmount = n.amount;
            if (n.user != user || nodeAmount == 0 || nodeAmount >= dustThreshold) revert InvalidCompactionRange();
            uint256 next = n.next;
            if (next == 0) revert InvalidCompactionRange();
            amount += nodeAmount;
            ++count;
            id = next;
        }
        if (id != intoId || count == 0 || amount == 0) revert InvalidCompactionRange();
        Node storage into = q.nodes[intoId];
        if (into.user != user || into.amount == 0) revert InvalidCompactionRange();

        _mergeChain(q, user, fromId, count, intoId);
        into.amount += amount;
        emit DebtCompacted(user, fromId, intoId, count, amount);
        resultId = intoId;
    }

    function computePositionPnl(
        uint64 entryPrice,
        uint64 markPrice,
        uint128 collateral,
        uint32 leverage,
        bool isLong,
        uint256 profitHaircut,
        uint256 impactA,
        uint256 impactB,
        uint256 impactC
    ) internal pure returns (int256 rawPnl, int256 pnl) {
        uint64 tolerance = entryPrice / 50_000;
        uint64 exitPrice;
        if (isLong) {
            if (markPrice > entryPrice + tolerance) exitPrice = markPrice - tolerance;
            else if (markPrice > entryPrice) exitPrice = entryPrice;
            else exitPrice = markPrice;
        } else {
            if (markPrice + tolerance < entryPrice) exitPrice = markPrice + tolerance;
            else if (markPrice < entryPrice) exitPrice = entryPrice;
            else exitPrice = markPrice;
        }
        int256 priceDelta = isLong
            ? int256(uint256(exitPrice)) - int256(uint256(entryPrice))
            : int256(uint256(entryPrice)) - int256(uint256(exitPrice));
        rawPnl = int256(uint256(collateral)) * int256(uint256(leverage)) * priceDelta / int256(uint256(entryPrice));
        if (rawPnl > 0) {
            pnl = applyImpact(rawPnl, entryPrice, exitPrice, profitHaircut, impactA, impactB, impactC);
        } else {
            int256 maxLoss = -int256(uint256(collateral));
            pnl = rawPnl < maxLoss ? maxLoss : rawPnl;
        }
    }

    function applyImpact(
        int256 pnl,
        uint64 entryPrice,
        uint64 exitPrice,
        uint256 profitHaircut,
        uint256 impactA,
        uint256 impactB,
        uint256 impactC
    ) internal pure returns (int256) {
        uint64 move = exitPrice >= entryPrice ? exitPrice - entryPrice : entryPrice - exitPrice;
        if (move == 0) return 0;
        uint256 denominator = _impactDenominator(uint256(move) * WAD / entryPrice, impactA, impactB, impactC);
        if (denominator == 0) return 0;
        uint256 factor = (WAD - profitHaircut) * WAD / denominator;
        return pnl * int256(factor) / int256(WAD);
    }

    function _impactDenominator(uint256 moveWad, uint256 impactA, uint256 impactB, uint256 impactC)
        private
        pure
        returns (uint256)
    {
        uint256 a = moveWad * impactA / WAD;
        uint256 inverseA = a == 0 ? type(uint256).max : 1e36 / a;
        uint256 b = 1e6 * moveWad * impactB / WAD;
        uint256 inverseB = b == 0 ? type(uint256).max : impactC * WAD / b;
        if (inverseA > 1e36 || inverseB > 1e36) return 0;
        return WAD + inverseA + inverseB;
    }

    function settle(
        QueueState storage q,
        address user,
        uint128 collateral,
        int256 pnl,
        bool usedCredits,
        uint256 winFeeRate,
        uint256 lossFeeRate,
        uint256 available
    ) internal returns (Settlement memory result) {
        bool queueEmpty = q.totalQueued == 0;
        uint256 owed;
        uint256 fee;
        if (pnl > 0) {
            fee = uint256(pnl) * winFeeRate / WAD;
            if (usedCredits) {
                owed = uint256(collateral) + uint256(pnl) - fee;
            } else {
                result.marginReturned = collateral;
                owed = uint256(pnl) - fee;
            }
        } else {
            uint256 loss;
            (loss, fee) = _lossAndFee(collateral, pnl, lossFeeRate);
            if (!usedCredits) {
                result.marginReturned = uint256(collateral) - loss;
                if (queueEmpty) {
                    result.stakerFee = fee >> 1;
                    result.devFee = fee - result.stakerFee;
                } else {
                    result.toSideBucket = loss;
                }
                return result;
            }
            owed = uint256(collateral) - loss;
        }

        if (queueEmpty) {
            if (available >= owed + fee) {
                result.stakerFee = fee >> 1;
                result.devFee = fee - result.stakerFee;
            }
            result.paidNow = owed <= available ? owed : available;
            result.queued = owed - result.paidNow;
        } else {
            result.queued = owed;
        }
        if (result.queued != 0) _enqueue(q, user, result.queued);
    }

    function _lossAndFee(uint128 collateral, int256 pnl, uint256 lossFeeRate)
        private
        pure
        returns (uint256 loss, uint256 fee)
    {
        loss = uint256(-pnl);
        if (loss > collateral) loss = collateral;
        fee = loss * lossFeeRate / WAD;
        if (fee > loss) fee = loss;
    }

    function _payNode(
        QueueState storage q,
        mapping(address => uint256) storage balances,
        uint256 id,
        uint256 available
    ) private returns (uint256 pay, bool settled) {
        Node storage n = q.nodes[id];
        uint256 nodeAmount = n.amount;
        if (nodeAmount == 0) return (0, true);
        address user = n.user;
        if (available < nodeAmount) {
            pay = available;
            n.amount = nodeAmount - available;
        } else {
            pay = nodeAmount;
            n.amount = 0;
            _unlink(q, id, user);
            settled = true;
        }
        balances[user] += pay;
        q.userQueuedTotal[user] -= pay;
        emit Harvested(user, pay, nodeAmount - pay);
    }

    function _scanDust(QueueState storage q, address user, uint256 firstId, uint256 maxMerges, uint256 dustThreshold)
        private
        view
        returns (uint256 count, uint256 amount, uint256 intoId)
    {
        uint256 id = firstId;
        while (id != 0 && count < maxMerges) {
            Node storage n = q.nodes[id];
            if (n.user != user || n.amount >= dustThreshold) break;
            uint256 next = n.next;
            if (next == 0) break;
            Node storage nextNode = q.nodes[next];
            if (nextNode.user != user || nextNode.amount == 0) break;
            ++count;
            amount += n.amount;
            intoId = next;
            if (nextNode.amount + amount >= dustThreshold) break;
            id = next;
        }
    }

    function _mergeChain(QueueState storage q, address user, uint256 firstId, uint256 count, uint256 intoId) private {
        uint256 id = firstId;
        for (uint256 i; i < count; ++i) {
            Node storage n = q.nodes[id];
            uint256 next = n.next;
            uint256 nodeAmount = n.amount;
            n.amount = 0;
            _unlink(q, id, user);
            _clearLinks(n);
            emit DebtNodeMerged(user, id, intoId == 0 ? next : intoId, nodeAmount);
            id = next;
        }
    }

    function _enqueue(QueueState storage q, address user, uint256 amount) private {
        if (amount == 0) return;
        uint256 id = q.nextId++;
        if (id > type(uint48).max) revert QueueIdOverflow();
        uint256 tail = q.userQueueTail[user];
        q.nodes[id] = Node({user: user, next: 0, prev: uint48(tail), amount: amount});
        if (q.head == 0) q.head = id;
        if (tail == 0) q.userQueueHead[user] = id;
        else q.nodes[tail].next = uint48(id);
        q.userQueueTail[user] = id;
        q.totalQueued += amount;
        q.userQueuedTotal[user] += amount;
        emit Enqueued(user, id, amount);
    }

    function _unlink(QueueState storage q, uint256 id, address user) private {
        Node storage n = q.nodes[id];
        uint48 prev = n.prev;
        uint48 next = n.next;
        if (prev != 0) q.nodes[prev].next = next;
        else q.userQueueHead[user] = next;
        if (next != 0) q.nodes[next].prev = prev;
        else q.userQueueTail[user] = prev;
    }

    function _clearLinks(Node storage n) private {
        n.next = 0;
        n.prev = 0;
    }
}
