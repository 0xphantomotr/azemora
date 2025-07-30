// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { DMRVManager } from "../../src/core/dMRVManager.sol";

contract RegisterModule is Script {
    function run() external {
        address dmrvManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        
        // The ID for the ReputationWeightedVerifier methodology
        bytes32 methodologyId = keccak256(bytes("ReputationWeightedVerifier_v2"));

        console.log("Registering methodology with dMRVManager...");
        // --- CORRECTED LOGGING ---
        console.log(" -> Methodology ID:");
        console.logBytes32(methodologyId);

        vm.startBroadcast();

        DMRVManager(dmrvManagerAddress).addVerifierModule(methodologyId);

        vm.stopBroadcast();

        console.log("Successfully registered the verifier module.");
    }
} 