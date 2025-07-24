// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

/**
 * @title ProposeMintScript
 * @dev A script to create a governance proposal to mint DynamicImpactCredits for a project.
 */
contract ProposeMintScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address dMRVManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        uint256 proposerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proposerAddress = vm.addr(proposerPrivateKey);

        // --- Prepare Project & Proposal Data ---
        string memory projectName = "My Test Reforestation Project";
        bytes32 projectId = keccak256(abi.encodePacked(projectName));
        uint256 amountToMint = 150 * 1e18; // Mint 150 credits
        string memory credentialCID = "ipfs://bafkreiapprovedcreditsforproject1";
        string memory description = "Proposal: Mint 150 credits for My Test Reforestation Project";

        // --- Build Proposal ---
        address[] memory targets = new address[](1);
        targets[0] = dMRVManagerAddress;

        uint256[] memory values = new uint256[](1); // 0 ETH
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            DMRVManager.adminSubmitVerification.selector,
            projectId,
            amountToMint,
            credentialCID,
            false // updateMetadataOnly
        );

        console.log("--- Creating Governance Proposal to Mint Credits ---");
        console.log("Governor Contract:", governorAddress);
        console.log("Proposer:", proposerAddress);
        console.log("Target Contract (DMRVManager):", targets[0]);
        console.log("Project ID:", vm.toString(projectId));
        console.log("Amount to Mint:", amountToMint);
        console.log("Description:", description);

        // --- Execute Transaction ---
        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));
        vm.startBroadcast(proposerPrivateKey);

        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.stopBroadcast();

        console.log("\nProposal created successfully!");
        console.log("Proposal ID:", proposalId);
        console.log("\nNext Steps:");
        console.log("1. Delegate voting power using 'Delegate.s.sol'");
        console.log("2. Vote on this proposal using 'Vote.s.sol'");
    }
}
