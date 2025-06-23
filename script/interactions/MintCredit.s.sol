// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

/**
 * @title MintCreditScript
 * @dev A script to simulate the dMRV process by requesting and fulfilling verification.
 * This version uses the modular verification flow.
 */
contract MintCreditScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address dMRVManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        if (dMRVManagerAddress == address(0)) {
            revert("DMRV_MANAGER_ADDRESS not set in .env file");
        }
        string memory moduleTypeStr = vm.envString("MODULE_TYPE");
        if (bytes(moduleTypeStr).length == 0) {
            revert("MODULE_TYPE not set in .env file (e.g., MOCK_MODULE)");
        }
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Prepare Project Data ---
        string memory projectName = "My Test Reforestation Project";
        bytes32 projectId = keccak256(abi.encodePacked(projectName));
        bytes32 claimId = keccak256(abi.encodePacked(projectId, block.timestamp)); // Simple unique claim ID
        bytes32 moduleType = keccak256(abi.encodePacked(moduleTypeStr));
        string memory evidenceURI = "ipfs://your-evidence-cid-goes-here";

        DMRVManager dMRVManager = DMRVManager(dMRVManagerAddress);

        // --- Execute Transactions in a single broadcast ---
        vm.startBroadcast(deployerPrivateKey);

        // 1. Request verification
        console.log("--- 1. Requesting Verification ---");
        console.log("   Project ID:", vm.toString(projectId));
        console.log("   Claim ID:  ", vm.toString(claimId));
        console.log("   Module Type:", moduleTypeStr);
        dMRVManager.requestVerification(projectId, claimId, evidenceURI, moduleType);
        console.log("On-chain request created successfully.");

        // 2. Fulfill verification (in a real scenario, this would be done by the module owner)
        console.log("\n--- 2. Fulfilling Verification (Simulated by Deployer) ---");
        uint256 creditAmount = 100 * 1e18; // Mint 100 credits
        string memory newMetaURI = "ipfs://bafkreinewmetadataforproject1";
        bytes memory verificationData = abi.encode(creditAmount, false, bytes32(0), newMetaURI);

        console.log("Fulfilling with amount:", creditAmount);
        // Note: For this script to work, the calling address (deployer) must be registered
        // as the module address for the given MODULE_TYPE in the dMRVManager.
        dMRVManager.fulfillVerification(projectId, claimId, verificationData);

        vm.stopBroadcast();

        console.log("\nCredit minting transaction sent successfully!");
        console.log("You can now use the Marketplace script to list this credit for sale.");
    }
}
