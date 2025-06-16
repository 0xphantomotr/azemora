// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Marketplace} from "../../src/marketplace/Marketplace.sol";

/**
 * @title CancelListingScript
 * @dev A script to cancel an active listing on the Azemora Marketplace.
 * This can only be run by the address that originally listed the item.
 */
contract CancelListingScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address marketplaceAddress = vm.envAddress("MARKETPLACE_ADDRESS");
        if (marketplaceAddress == address(0)) {
            revert("MARKETPLACE_ADDRESS not set in .env file");
        }

        // The private key of the user who created the listing
        uint256 sellerPrivateKey = vm.envUint("PRIVATE_KEY");
        address sellerAddress = vm.addr(sellerPrivateKey);

        // --- Script Configuration ---
        // IMPORTANT: You may need to change this ID.
        // This should be the ID of an *active* listing created by the seller.
        uint256 listingIdToCancel = 1;

        // --- Contract Instance ---
        Marketplace marketplace = Marketplace(marketplaceAddress);

        // --- Pre-transaction Checks ---
        Marketplace.Listing memory listing = marketplace.getListing(listingIdToCancel);
        require(listing.active, "Listing is not active or does not exist.");
        require(listing.seller == sellerAddress, "You are not the seller of this listing.");

        console.log("--- Cancelling Listing ---");
        console.log("Marketplace Contract:", marketplaceAddress);
        console.log("Seller Address:", sellerAddress);
        console.log("Listing ID to Cancel:", listingIdToCancel);
        console.log("Tokens to be returned:", listing.amount);

        // --- Execute Transaction ---
        vm.startBroadcast(sellerPrivateKey);

        marketplace.cancelListing(listingIdToCancel);

        vm.stopBroadcast();

        console.log("\nListing cancellation transaction sent successfully!");
        console.log("Unsold tokens have been returned to the seller.");
    }
}
