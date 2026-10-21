// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract Martingaler {
    using SafeERC20 for IERC20;

    struct Entry {
        address user;
        uint256 amount;
    }

    error UnsupportedCollateralDecimals();

    IERC20 public collateralToken;
    uint256 public collateralScale;
    uint256 public treasury;
    uint256 public queueHead;
    uint256 public queueTail;
    uint256 public treasuryDebt;
    mapping(uint256 => Entry) public queue;
    mapping(address => uint256) public treasuryDebtOf;

    event Enqueued(address indexed user, uint256 indexed id, uint256 amount);
    event Debited(address indexed user, uint256 amount);
    event QueuePaid(address indexed user, uint256 indexed id, uint256 amount, uint256 remaining);

    function harvest(uint256 maxEntries) external returns (uint256 settled) {
        while (settled < maxEntries && _payFront()) ++settled;
    }

    function queueLength() public view returns (uint256) {
        return queueTail - queueHead;
    }

    function _initCollateral(address token) internal {
        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals > 18) revert UnsupportedCollateralDecimals();

        collateralToken = IERC20(token);
        collateralScale = 10 ** uint256(18 - decimals);
    }

    function _debit(address user, uint256 amount) internal returns (uint256 debited) {
        uint256 debt = treasuryDebtOf[user];
        debited = Math.min(debt, amount);
        debited -= debited % collateralScale;

        if (debited != 0) {
            treasuryDebtOf[user] = debt - debited;
            treasuryDebt -= debited;
            emit Debited(user, debited);
        }

        uint256 cash = amount - debited;
        if (cash != 0) collateralToken.safeTransferFrom(user, address(this), cash / collateralScale);
    }

    function _pay(address user, uint256 amount) internal {
        uint256 dust = amount % collateralScale;
        treasury += dust;
        uint256 tokens = (amount - dust) / collateralScale;
        if (tokens != 0) collateralToken.safeTransfer(user, tokens);
    }

    function _settleLoss(uint256 amount) internal {
        treasury += amount;
    }

    function _settleWin(address user, uint256 amount) internal returns (uint256 paid, uint256 queued) {
        (paid, queued) = queueLength() == 0 ? _splitByTreasury(amount) : (0, amount);

        if (paid != 0) {
            treasury -= paid;
            _pay(user, paid);
        }

        if (queued != 0) {
            uint256 id = queueTail++;
            queue[id] = Entry(user, queued);
            treasuryDebt += queued;
            treasuryDebtOf[user] += queued;
            emit Enqueued(user, id, queued);
        }
    }

    function _payFront() internal returns (bool settled) {
        if (queueLength() == 0) return false;

        uint256 id = queueHead;
        Entry storage e = queue[id];
        uint256 remainingDebt = treasuryDebtOf[e.user];
        uint256 payableFromEntry = Math.min(e.amount, remainingDebt);
        (uint256 paid, uint256 remaining) = _splitByTreasury(payableFromEntry);
        if (paid == 0 && remaining != 0) return false;

        if (paid != 0) {
            treasury -= paid;
            treasuryDebt -= paid;
            treasuryDebtOf[e.user] = remainingDebt - paid;
            _pay(e.user, paid);
        }
        emit QueuePaid(e.user, id, paid, remaining);

        settled = remaining == 0;
        if (settled) {
            delete queue[id];
            queueHead = id + 1;
        } else {
            e.amount = remaining;
        }
    }

    function _splitByTreasury(uint256 amount) private view returns (uint256 covered, uint256 remaining) {
        covered = Math.min(amount, treasury);
        remaining = amount - covered;
    }
}
