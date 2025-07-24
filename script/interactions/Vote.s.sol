// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";

/**
 * @title VoteScript
 * @dev A script to vote on a governance proposal.
 */
contract VoteScript is Script {
    function run() external {
        // --- Use the correct hex value for the Proposal ID ---
        uint256 proposalId = 6882719540068179991427622714661728303569774533887008696370161192431493079835;

        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        uint256 voterPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Vote ---
        // 0 = Against, 1 = For, 2 = Abstain
        uint8 vote = 1;
        string memory reason = "I approve this proposal.";

        vm.startBroadcast(voterPrivateKey);

        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));
        governor.castVoteWithReason(proposalId, vote, reason);

        vm.stopBroadcast();

        console.log("\nVote cast successfully!");
        console.log("  Proposal ID:", proposalId);
        console.log("  Vote:", "For");
        console.log("  Reason:", reason);
    }
}
