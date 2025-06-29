// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";

/**
 * @title StateScript
 * @dev A script to check the state of a governance proposal.
 */
contract StateScript is Script {
    function run() public view {
        // --- Hardcoded Proposal ID for Debugging (using hex) ---
        uint256 proposalId = 0x847acabca3865e2f865c34907159855eded32342f0708044a4302efcc12748e3;

        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");

        // --- Contract Instance ---
        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));

        // --- Get State ---
        // This is a view call, so no broadcast is needed.
        AzemoraGovernor.ProposalState proposalState = governor.state(proposalId);

        console.log("\n--- Proposal State ---");
        console.log("Proposal ID:", proposalId);

        if (uint8(proposalState) == 0) {
            console.log("State: Pending");
        } else if (uint8(proposalState) == 1) {
            console.log("State: Active");
        } else if (uint8(proposalState) == 2) {
            console.log("State: Canceled");
        } else if (uint8(proposalState) == 3) {
            console.log("State: Defeated");
        } else if (uint8(proposalState) == 4) {
            console.log("State: Succeeded");
        } else if (uint8(proposalState) == 5) {
            console.log("State: Queued");
        } else if (uint8(proposalState) == 6) {
            console.log("State: Expired");
        } else if (uint8(proposalState) == 7) {
            console.log("State: Executed");
        }
    }
}
