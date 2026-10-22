// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PerpetualFutures} from "../../src/PerpetualFutures.sol";
import {OpenRequest, CloseRequest} from "../../src/interfaces/IPerpetualFutures.sol";

abstract contract PerpsSigner is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant OPEN_TYPEHASH = keccak256(
        "OpenPosition(address trader,uint32 instrumentId,bool isLong,uint128 collateral,uint32 leverage,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant CLOSE_TYPEHASH =
        keccak256("ClosePositions(address trader,uint256[] positionIds,uint256 nonce,uint256 deadline)");

    mapping(address => uint256) internal keyOf;
    uint192 internal lastNonceKey;

    function makeTrader(string memory name) internal returns (address trader) {
        uint256 key;
        (trader, key) = makeAddrAndKey(name);
        keyOf[trader] = key;
    }

    function freshNonce() internal returns (uint256) {
        return uint256(++lastNonceKey) << 64;
    }

    function openRequest(address trader, uint32 market, bool isLong, uint256 margin, uint256 leverage)
        internal
        returns (OpenRequest memory)
    {
        return OpenRequest({
            trader: trader,
            instrumentId: market,
            isLong: isLong,
            collateral: uint128(margin),
            leverage: uint32(leverage),
            nonce: freshNonce(),
            deadline: block.timestamp
        });
    }

    function closeRequest(address trader, uint256[] memory ids) internal returns (CloseRequest memory) {
        return CloseRequest({trader: trader, positionIds: ids, nonce: freshNonce(), deadline: block.timestamp});
    }

    function sign(PerpetualFutures perps, uint256 key, OpenRequest memory r) internal view returns (bytes memory) {
        return signDigest(
            perps,
            key,
            keccak256(
                abi.encode(
                    OPEN_TYPEHASH, r.trader, r.instrumentId, r.isLong, r.collateral, r.leverage, r.nonce, r.deadline
                )
            )
        );
    }

    function sign(PerpetualFutures perps, uint256 key, CloseRequest memory r) internal view returns (bytes memory) {
        return signDigest(
            perps,
            key,
            keccak256(
                abi.encode(CLOSE_TYPEHASH, r.trader, keccak256(abi.encodePacked(r.positionIds)), r.nonce, r.deadline)
            )
        );
    }

    function signDigest(PerpetualFutures perps, uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("PerpetualFutures"), keccak256("1"), block.chainid, address(perps))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
