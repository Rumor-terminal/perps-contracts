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
    uint256 public queuedTotal;
    mapping(uint256 => Entry) public queue;
    mapping(address => uint256) public queuedOf;

    event Enqueued(address indexed user, uint256 indexed id, uint256 amount);
    event QueuePaid(
        address indexed user,
        uint256 indexed id,
        uint256 amount,
        uint256 remaining
    );

    function harvest(uint256 maxEntries) external returns (uint256 paid) {
        while (paid < maxEntries && _payFront()) ++paid;
    }

    function queueLength() public view returns (uint256) {
        return queueTail - queueHead;
    }

    function _credit(address user, uint256 amount) internal virtual;

    function _settleLoss(uint256 amount) internal {
        treasury += amount;
    }

    function _settleWin(
        address user,
        uint256 amount
    ) internal returns (uint256 instantAmount, uint256 queuedAmount) {
        (instantAmount, queuedAmount) = queueLength() == 0
            ? (treasury > amount ? (amount, 0) : (treasury, amount - treasury))
            : (0, amount);

        if (instantAmount > 0) {
            treasury -= instantAmount;
            _credit(user, instantAmount);
        }

        if (queuedAmount > 0) {
            uint256 id = queueTail++;
            queue[id] = Entry(user, queuedAmount);
            queuedTotal += queuedAmount;
            queuedOf[user] += queuedAmount;
            emit Enqueued(user, id, queuedAmount);
        }
    }

    function _payFront() internal returns (bool settled) {
        if (queueLength() == 0) return false;
        uint256 id = queueHead;
        Entry storage e = queue[id];
        (uint256 payoutAmount, uint256 remainingAmount) = treasury > e.amount
            ? (e.amount, 0)
            : (treasury, e.amount - treasury);
        if (payoutAmount == 0) return false;

        treasury -= payoutAmount;
        queuedTotal -= payoutAmount;
        queuedOf[e.user] -= payoutAmount;
        _credit(e.user, payoutAmount);
        emit QueuePaid(e.user, id, payoutAmount, remainingAmount);

        settled = remainingAmount == 0;
        if (settled) {
            delete queue[id];
            queueHead = id + 1;
        } else {
            e.amount = remainingAmount;
        }
    }
}
