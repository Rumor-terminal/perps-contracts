// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PerpetualFutures} from "../src/PerpetualFutures.sol";

contract Upgrade is Script {
    function run() external {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        PerpetualFutures perps = PerpetualFutures(payable(vm.parseJsonAddress(vm.readFile(path), ".exchange")));

        vm.startBroadcast();
        address implementation = address(new PerpetualFutures());
        perps.upgradeToAndCall(implementation, "");
        vm.stopBroadcast();

        vm.writeJson(vm.toString(implementation), path, ".implementation");
        console.log("implementation", implementation);
    }
}
