// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraToken} from "../../src/token/AzemoraToken.sol";

/**
 * @title DelegateScript
 * @dev A script to delegate voting power to the caller.
 */
contract DelegateScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        uint256 delegatorPrivateKey = vm.envUint("PRIVATE_KEY");
        address delegatorAddress = vm.addr(delegatorPrivateKey);

        // --- Contract Instances ---
        AzemoraToken token = AzemoraToken(tokenAddress);

        console.log("--- Delegating Voting Power ---");
        console.log("Token Contract:", tokenAddress);
        console.log("Delegator:", delegatorAddress);
        console.log("Delegating to (self):", delegatorAddress);

        // --- Execute Transaction ---
        vm.startBroadcast(delegatorPrivateKey);

        token.delegate(delegatorAddress);

        vm.stopBroadcast();

        console.log("\nDelegation successful!");
        console.log("Voting power for", delegatorAddress, "is now:", token.getVotes(delegatorAddress));
    }
}
