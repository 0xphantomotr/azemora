// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

/**
 * @title QueueScript
 * @dev A script to queue a passed governance proposal.
 */
contract QueueScript is Script {
    function run() external {
        // --- Use the correct Proposal ID from the proposal script's output ---
        uint256 proposalId = 6882719540068179991427622714661728303569774533887008696370161192431493079835;

        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address dMRVManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        uint256 queuerPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Reconstruct Proposal Details to get the descriptionHash ---
        string memory projectName = "My Test Reforestation Project";
        bytes32 projectId = keccak256(abi.encodePacked(projectName));
        uint256 amountToMint = 150 * 1e18;
        string memory credentialCID = "ipfs://bafkreiapprovedcreditsforproject1";
        string memory description = "Proposal: Mint 150 credits for My Test Reforestation Project";
        bytes32 descriptionHash = keccak256(bytes(description));

        address[] memory targets = new address[](1);
        targets[0] = dMRVManagerAddress;

        uint256[] memory values = new uint256[](1); // 0 ETH

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            DMRVManager.adminSubmitVerification.selector,
            projectId,
            amountToMint,
            credentialCID,
            false // updateMetadataOnly
        );

        // --- Queue the Proposal ---
        console.log("--- Queuing Proposal ---");
        console.log("Proposal ID:", proposalId);

        vm.startBroadcast(queuerPrivateKey);

        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.stopBroadcast();

        console.log("\nProposal queued successfully!");
        console.log("Next Step: Wait for the timelock delay and then run 'Execute.s.sol'");
    }
}
