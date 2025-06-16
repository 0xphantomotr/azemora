// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

/**
 * @title MintCreditScript
 * @dev A script to simulate the dMRV process by requesting and fulfilling verification.
 * This version captures the returned requestId to ensure correctness.
 */
contract MintCreditScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address dMRVManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        if (dMRVManagerAddress == address(0)) {
            revert("DMRV_MANAGER_ADDRESS not set in .env file");
        }
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Prepare Project Data ---
        string memory projectName = "My Test Reforestation Project";
        bytes32 projectId = keccak256(abi.encodePacked(projectName));

        DMRVManager dMRVManager = DMRVManager(dMRVManagerAddress);

        // --- Execute Transactions in a single broadcast ---
        // Foundry simulates this whole block, so the requestId from the first
        // call is available to the second call.
        vm.startBroadcast(deployerPrivateKey);

        // 1. Request verification and CAPTURE the real requestId
        console.log("--- 1. Requesting Verification ---");
        bytes32 requestId = dMRVManager.requestVerification(projectId);
        console.log("On-chain request created with ID:", vm.toString(requestId));

        // 2. Fulfill verification using the CAPTURED ID
        console.log("\n--- 2. Fulfilling Verification ---");
        uint256 creditAmount = 100 * 1e18; // Mint 100 credits
        string memory newMetaURI = "ipfs://bafkreinewmetadataforproject1";
        bytes memory verificationData = abi.encode(creditAmount, false, bytes32(0), newMetaURI);

        console.log("Fulfilling with amount:", creditAmount);
        dMRVManager.fulfillVerification(requestId, verificationData);

        vm.stopBroadcast();

        console.log("\nCredit minting transaction sent successfully!");
        console.log("You can now use the Marketplace script to list this credit for sale.");
    }
}
