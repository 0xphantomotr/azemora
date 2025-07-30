// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { MethodologyRegistry } from "../../src/core/MethodologyRegistry.sol";

contract GrantRole is Script {
    function run() external {
        address methodologyRegistryAddress = vm.envAddress("METHODOLOGY_REGISTRY_ADDRESS");
        address myAddress = vm.envAddress("INITIAL_ADMIN_ADDRESS");
        bytes32 adminRole = MethodologyRegistry(methodologyRegistryAddress).DEFAULT_ADMIN_ROLE();

        console.log("Granting DEFAULT_ADMIN_ROLE to personal wallet for testing...");
        
        vm.startBroadcast();
        
        MethodologyRegistry(methodologyRegistryAddress).grantRole(adminRole, myAddress);

        vm.stopBroadcast();

        console.log("Role granted successfully.");
    }
} 