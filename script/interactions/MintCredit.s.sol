// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

/**
 * @title AdminMintCreditScript
 * @dev A script for an admin to directly mint impact credits, bypassing the module system.
 * This is useful for testing, manual corrections, or for systems where an off-chain
 * entity is the sole trusted verifier.
 */
contract AdminMintCreditScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address dMRVManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        if (dMRVManagerAddress == address(0)) {
            revert("DMRV_MANAGER_ADDRESS not set in .env file");
        }
        uint256 adminPrivateKey = vm.envUint("PRIVATE_KEY"); // The deployer has the admin role

        // --- Prepare Project Data ---
        string memory projectName = "My Test Reforestation Project";
        bytes32 projectId = keccak256(abi.encodePacked(projectName));
        uint256 amountToMint = 150 * 1e18; // Mint 150 credits
        string memory credentialCID = "ipfs://bafkreiapprovedcreditsforproject1";

        console.log("--- Admin Minting Credits ---");
        console.log("   dMRVManager:", dMRVManagerAddress);
        console.log("   Project ID: ", vm.toString(projectId));
        console.log("   Amount:     ", amountToMint);
        console.log("   Credential: ", credentialCID);

        DMRVManager dMRVManager = DMRVManager(dMRVManagerAddress);

        // --- Execute Transaction ---
        vm.startBroadcast(adminPrivateKey);

        // Directly mint credits using the admin-privileged function.
        // The last parameter `updateMetadataOnly` is false because we want to mint new tokens.
        dMRVManager.adminSubmitVerification(projectId, amountToMint, credentialCID, false);

        vm.stopBroadcast();

        console.log("\nCredit minting transaction sent successfully!");
        console.log("The project owner now has 150 new credits.");
        console.log("Next Step: Use the 'ListCredit.s.sol' script to put them on the marketplace.");
    }
}
