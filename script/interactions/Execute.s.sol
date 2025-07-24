// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

/**
 * @title ExecuteScript
 * @dev A script to execute a queued governance proposal.
 * THIS SCRIPT IS A MIRROR OF THE SUCCESSFUL QUEUE SCRIPT.
 */
contract ExecuteScript is Script {
    function run() external {
        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address dMRVManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        uint256 executorPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Reconstruct Proposal Details EXACTLY like in Queue.s.sol ---
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

        // --- Execute the Proposal ---
        console.log("--- Executing Proposal ---");

        vm.startBroadcast(executorPrivateKey);

        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));
        governor.execute(targets, values, calldatas, descriptionHash);

        vm.stopBroadcast();

        console.log("\nProposal executed successfully!");
        console.log("  Description:", description);
    }
}
