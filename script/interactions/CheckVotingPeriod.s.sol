// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";

/**
 * @title CheckVotingPeriod
 * @dev A script to read the configured voting period directly from the deployed Governor contract.
 */
contract CheckVotingPeriod is Script {
    function run() public view {
        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        if (governorAddress == address(0)) {
            console.log("Error: GOVERNOR_ADDRESS not found in environment. Make sure your .env file is loaded.");
            return;
        }

        // --- Contract Instance ---
        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));

        // --- Get Voting Period ---
        uint256 votingPeriod = governor.votingPeriod();

        console.log("\n--- Governor Settings On-Chain ---");
        console.log("Deployed Governor Address:", governorAddress);
        console.log("Voting Period (in blocks):", votingPeriod);

        if (votingPeriod == 40320) {
            console.log("--> This is the default ~7 day period.");
        } else if (votingPeriod == 1000) {
            console.log("--> This is the ~20-30 minute period from your .env file.");
        }
    }
}
