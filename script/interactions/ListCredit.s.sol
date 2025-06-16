// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Marketplace} from "../../src/marketplace/Marketplace.sol";
import {DynamicImpactCredit} from "../../src/core/DynamicImpactCredit.sol";

/**
 * @title ListCreditScript
 * @dev A script to list a freshly minted Dynamic Impact Credit on the marketplace.
 */
contract ListCreditScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address marketplaceAddress = vm.envAddress("MARKETPLACE_ADDRESS");
        address creditAddress = vm.envAddress("DYNAMIC_IMPACT_CREDIT_ADDRESS");
        if (marketplaceAddress == address(0) || creditAddress == address(0)) {
            revert("Required contract addresses not set in .env file");
        }
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Prepare Listing Data ---
        // The tokenId for our credit is the projectId.
        string memory projectName = "My Test Reforestation Project";
        bytes32 projectId = keccak256(abi.encodePacked(projectName));
        uint256 tokenId = uint256(projectId);

        uint256 listAmount = 50 * 1e18; // List 50 of the 100 credits we minted
        uint256 pricePerUnit = 1 ether; // List them for 1 mock-USDC each
        uint256 expiryDuration = 7 days;

        console.log("--- Listing Credit on Marketplace ---");
        console.log("Marketplace Contract:", marketplaceAddress);
        console.log("Token ID (Project ID):", tokenId);

        DynamicImpactCredit creditContract = DynamicImpactCredit(creditAddress);
        Marketplace marketplace = Marketplace(marketplaceAddress);

        // --- Execute Transactions ---
        vm.startBroadcast(deployerPrivateKey);

        // 1. Approve the Marketplace to spend our credits
        console.log("\n1. Approving marketplace...");
        creditContract.setApprovalForAll(marketplaceAddress, true);

        // 2. List the credits for sale
        console.log("2. Listing credits...");
        uint256 listingId = marketplace.list(tokenId, listAmount, pricePerUnit, expiryDuration);
        console.log("Successfully listed with Listing ID:", listingId);

        vm.stopBroadcast();

        console.log(" Credit listed successfully!");
    }
}
