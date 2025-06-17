// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TransferScript
 * @dev A script to transfer ERC20 tokens to the Treasury contract.
 */
contract TransferScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address treasuryAddress = vm.envAddress("TREASURY_ADDRESS");
        uint256 senderPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Script Configuration ---
        // Transfer 1,000 tokens to the treasury.
        // Assumes the token has 18 decimals.
        uint256 amountToTransfer = 1000 * (10 ** 18);

        // --- Contract Instances ---
        IERC20 token = IERC20(tokenAddress);
        address senderAddress = vm.addr(senderPrivateKey);

        console.log("--- Transferring Tokens to Treasury ---");
        console.log("Token Contract:", tokenAddress);
        console.log("Sender:", senderAddress);
        console.log("Recipient (Treasury):", treasuryAddress);
        console.log("Amount:", amountToTransfer);

        // --- Execute Transaction ---
        vm.startBroadcast(senderPrivateKey);

        bool success = token.transfer(treasuryAddress, amountToTransfer);
        require(success, "Token transfer failed.");

        vm.stopBroadcast();

        console.log("\nTransfer successful!");
        console.log("Treasury now holds", token.balanceOf(treasuryAddress), "tokens.");
    }
}
