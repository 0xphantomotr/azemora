// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

contract SubmitVerification is Script {
    function run() external {
        // Load environment variables
        address dmrvManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        bytes32 projectId = vm.envBytes32("TEST_PROJECT_ID");

        if (projectId == bytes32(0)) {
            revert("TEST_PROJECT_ID not set in .env file.");
        }

        // Define test data
        bytes32 claimId = keccak256(abi.encodePacked(projectId, block.timestamp));
        string memory evidenceURI = "ipfs://bafkreid335c3rtf2nve5kh7c6o4fxn5g4s2j4j6h7j8c9k0l1m2n3o4p5q";
        uint256 amount = 100 * 1e18; // Requesting 100 credits
        bytes32 methodologyId = keccak256(bytes("ReputationWeightedVerifier_v2"));

        vm.startBroadcast();

        DMRVManager(dmrvManagerAddress).requestVerification(projectId, claimId, evidenceURI, amount, methodologyId);

        vm.stopBroadcast();

        console.log("Successfully submitted verification task for project.");
        // --- CORRECTED LOGGING ---
        console.log(" -> Project ID:");
        console.logBytes32(projectId);
        console.log(" -> Claim ID:");
        console.logBytes32(claimId);
    }
}
