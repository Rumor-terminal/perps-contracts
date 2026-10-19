// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

abstract contract Martingaler {
    struct Entry {
        address user;
        uint256 amount;
    }

    uint256 public treasury;
    uint256 public queueHead;
    uint256 public queueTail;
    uint256 public treasuryDebt;
    mapping(uint256 => Entry) public queue;
    mapping(address => uint256) public treasuryDebtOf;

    event Enqueued(address indexed user, uint256 indexed id, uint256 amount);
    event Debited(address indexed user, uint256 amount);
    event QueuePaid(address indexed user, uint256 indexed id, uint256 amount, uint256 remaining);

    function harvest(uint256 maxEntries) external returns (uint256 paid) {
        while (paid < maxEntries && _payFront()) ++paid;
    }

    function queueLength() public view returns (uint256) {
        return queueTail - queueHead;
    }

    function _pay(address user, uint256 amount) internal virtual;

    function _tryDebit(address user, uint256 amount, uint256 unit)
        internal
        returns (uint256 debited, uint256 shouldPay)
    {
        uint256 debt = treasuryDebtOf[user];
        debited = debt < amount ? debt : amount;
        debited -= debited % unit;
        shouldPay = amount - debited;
        if (debited == 0) return (0, amount);

        treasuryDebtOf[user] = debt - debited;
        treasuryDebt -= debited;
        emit Debited(user, debited);
    }

    function _settleLoss(uint256 amount) internal {
        treasury += amount;
    }

    function _settleWin(address user, uint256 amount) internal returns (uint256 instantAmount, uint256 queuedAmount) {
        (instantAmount, queuedAmount) = queueLength() == 0 ? _splitByTreasury(amount) : (0, amount);

        if (instantAmount > 0) {
            treasury -= instantAmount;
            _pay(user, instantAmount);
        }

        if (queuedAmount > 0) {
            uint256 id = queueTail++;
            queue[id] = Entry(user, queuedAmount);
            treasuryDebt += queuedAmount;
            treasuryDebtOf[user] += queuedAmount;
            emit Enqueued(user, id, queuedAmount);
        }
    }

    function _payFront() internal returns (bool settled) {
        if (queueLength() == 0) return false;

        uint256 id = queueHead;
        Entry storage e = queue[id];
        uint256 debt = treasuryDebtOf[e.user];
        uint256 owed = e.amount < debt ? e.amount : debt;
        (uint256 payout, uint256 remaining) = _splitByTreasury(owed);
        if (payout == 0 && remaining != 0) return false;

        if (payout != 0) {
            treasury -= payout;
            treasuryDebt -= payout;
            treasuryDebtOf[e.user] = debt - payout;
            _pay(e.user, payout);
        }
        emit QueuePaid(e.user, id, payout, remaining);

        settled = remaining == 0;
        if (settled) {
            delete queue[id];
            queueHead = id + 1;
        } else {
            e.amount = remaining;
        }
    }

    function _splitByTreasury(uint256 amount) private view returns (uint256 payableNow, uint256 shortfall) {
        return amount <= treasury ? (amount, 0) : (treasury, amount - treasury);
    }
}
