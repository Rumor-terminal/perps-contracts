// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {Exchange} from "../src/Exchange.sol";
import {IExchange} from "../src/interfaces/IExchange.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract Deploy is Script {
    bytes32 constant BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant SOL_USD = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    bytes32 constant BNB_USD = 0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f;

    function run() external {
        bool isLocal = block.chainid == 31337;
        address pyth = isLocal ? address(0) : vm.envAddress("PYTH_ADDRESS");
        address usdc = isLocal ? address(0) : vm.envOr("USDC_ADDRESS", address(0));

        vm.startBroadcast();
        address deployer = msg.sender;
        if (isLocal) pyth = address(new MockPyth(60, 1));
        if (usdc == address(0)) usdc = address(new MockUSDC());

        Exchange exchange = new Exchange(deployer, pyth, usdc);
        exchange.setTradeMinimums(10e18, 1000e18);
        exchange.setMaxPriceAge(isLocal ? 3600 : 120);
        exchange.addInstrument(_instrument(BTC_USD), 1e8, "BTC");
        exchange.addInstrument(_instrument(ETH_USD), 1e8, "ETH");
        exchange.addInstrument(_instrument(SOL_USD), 1e8, "SOL");
        exchange.addInstrument(_instrument(BNB_USD), 1e8, "BNB");
        vm.stopBroadcast();

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "exchange", address(exchange));
        vm.serializeAddress(json, "pyth", pyth);
        vm.serializeAddress(json, "usdc", usdc);
        vm.serializeUint(json, "startBlock", block.number);
        string memory out = vm.serializeBool(json, "mockPyth", isLocal);
        vm.writeJson(out, string.concat("../deployments/", vm.toString(block.chainid), ".json"));
        console.log("exchange", address(exchange));
        console.log("pyth", pyth);
        console.log("usdc", usdc);
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
}
