// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PerpetualFutures} from "../src/PerpetualFutures.sol";
import {MulticallExecutor} from "../src/MulticallExecutor.sol";

contract DeployMulticall is Script {
    function run() external {
        string memory path = string.concat("../deployments/", vm.toString(block.chainid), ".json");
        PerpetualFutures perps = PerpetualFutures(payable(vm.parseJsonAddress(vm.readFile(path), ".exchange")));

        vm.startBroadcast();
        MulticallExecutor multicall = new MulticallExecutor(perps);
        perps.setExecutor(address(multicall), true);
        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(multicall)), path, ".multicall");
        console.log("multicall", address(multicall));
    }
}
