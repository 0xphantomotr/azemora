// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Marketplace} from "../../src/marketplace/Marketplace.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BuyCreditScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address marketplaceAddress = vm.envAddress("MARKETPLACE_ADDRESS");
        address paymentTokenAddress = vm.envAddress("MOCK_ERC20_ADDRESS");
        uint256 buyerPrivateKey = vm.envUint("PRIVATE_KEY");
        address buyerAddress = vm.addr(buyerPrivateKey);

        // --- Script Configuration ---
        uint256 listingIdToBuy = 1; // The ID of the listing to buy
        uint256 amountToBuy = 1; // The amount of credits to buy from the listing

        // --- Contract Instances ---
        Marketplace marketplace = Marketplace(marketplaceAddress);
        IERC20 paymentToken = IERC20(paymentTokenAddress);

        // --- Pre-transaction Checks ---
        Marketplace.Listing memory listing = marketplace.getListing(listingIdToBuy);
        require(listing.active, "Listing is not active.");
        require(listing.amount >= amountToBuy, "Not enough items in listing to fulfill the purchase.");

        uint256 totalPrice = amountToBuy * listing.pricePerUnit;
        require(paymentToken.balanceOf(buyerAddress) >= totalPrice, "Buyer does not have enough payment tokens.");

        console.log("--- Buying Credit ---");
        console.log("Marketplace Contract:", marketplaceAddress);
        console.log("Buyer Address:", buyerAddress);
        console.log("Listing ID:", listingIdToBuy);
        console.log("Amount to Buy:", amountToBuy);
        console.log("Price per unit:", listing.pricePerUnit);
        console.log("Total Price:", totalPrice);

        // --- Approve Marketplace to spend buyer's tokens ---
        vm.startBroadcast(buyerPrivateKey);

        console.log("\nApproving marketplace to spend tokens...");
        paymentToken.approve(marketplaceAddress, totalPrice);

        // --- Execute Purchase ---
        console.log("Executing purchase...");
        marketplace.buy(listingIdToBuy, amountToBuy);

        vm.stopBroadcast();

        console.log("\nCredit purchase transaction sent successfully!");
    }
}
