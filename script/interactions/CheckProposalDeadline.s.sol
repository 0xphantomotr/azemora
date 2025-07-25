// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";

/**
 * @title CheckProposalDeadline
 * @dev A script to read the deadline for a proposal directly from the Governor contract.
 */
contract CheckProposalDeadline is Script {
    function run() public view {
        // --- Hardcoded Proposal ID for Debugging ---
        uint256 proposalId = 46482692473281245105756105293512398332063573339722852850225954674196225401082;

        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        if (governorAddress == address(0)) {
            console.log("Error: GOVERNOR_ADDRESS not found in environment. Make sure your .env file is loaded.");
            return;
        }

        // --- Contract Instance ---
        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));

        // --- Get Deadline ---
        uint256 deadline = governor.proposalDeadline(proposalId);
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        uint256 currentBlock = block.number;

        console.log("\n--- Proposal Deadline On-Chain ---");
        console.log("Deployed Governor Address:", governorAddress);
        console.log("Proposal ID:", proposalId);
        console.log("Proposal Snapshot Block:", snapshot);
        console.log("Proposal Deadline Block:", deadline);
        console.log("Current Block Number:", currentBlock);

        if (currentBlock >= deadline) {
            console.log("--> STATUS: The deadline HAS passed.");
        } else {
            console.log("--> STATUS: The deadline has NOT passed yet.");
            console.log("    Blocks remaining:", deadline - currentBlock);
        }
    }
}
