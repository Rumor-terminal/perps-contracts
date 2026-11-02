// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {IPerpetualFutures, OpenRequest, CloseRequest} from "./interfaces/IPerpetualFutures.sol";

contract MulticallExecutor {
    IPerpetualFutures public immutable exchange;

    constructor(IPerpetualFutures exchange_) {
        exchange = exchange_;
    }

    function execute(
        OpenRequest[] calldata opens,
        bytes[] calldata openSignatures,
        CloseRequest[] calldata closes,
        bytes[] calldata closeSignatures,
        bytes[] calldata priceUpdate
    ) external payable {
        require(exchange.isExecutor(msg.sender));
        if (priceUpdate.length != 0) {
            exchange.pyth().updatePriceFeeds{value: msg.value}(priceUpdate);
        }

        bytes[] memory noPriceUpdate = new bytes[](0);
        for (uint256 i; i < opens.length; ++i) {
            try exchange.openPosition(opens[i], openSignatures[i], noPriceUpdate) {} catch {}
        }
        for (uint256 i; i < closes.length; ++i) {
            try exchange.closePositionsWithSig(closes[i], closeSignatures[i], noPriceUpdate) {} catch {}
        }
    }
}
