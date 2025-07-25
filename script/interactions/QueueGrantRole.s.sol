// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";

/**
 * @title QueueGrantRoleScript
 * @dev A script to queue a passed governance proposal to grant the VERIFIER_ROLE.
 */
contract QueueGrantRoleScript is Script {
    function run() external {
        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address projectRegistryAddress = vm.envAddress("PROJECT_REGISTRY_ADDRESS");
        uint256 queuerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 verifierPrivateKey = vm.envUint("VERIFIER_PRIVATE_KEY");
        address verifierAddress = vm.addr(verifierPrivateKey);

        // --- Reconstruct Proposal Details EXACTLY as in ProposeGrantRole.s.sol ---
        bytes32 verifierRole = ProjectRegistry(projectRegistryAddress).VERIFIER_ROLE();

        address[] memory targets = new address[](1);
        targets[0] = projectRegistryAddress;

        uint256[] memory values = new uint256[](1); // 0 ETH

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeWithSelector(bytes4(keccak256("grantRole(bytes32,address)")), verifierRole, verifierAddress);

        string memory description =
            string(abi.encodePacked("Proposal: Grant VERIFIER_ROLE to ", vm.toString(verifierAddress)));
        bytes32 descriptionHash = keccak256(bytes(description));

        // --- Queue the Proposal ---
        console.log("--- Queuing Proposal ---");

        vm.startBroadcast(queuerPrivateKey);

        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.stopBroadcast();

        console.log("\nProposal queued successfully!");
        console.log("Next Step: Wait for the timelock delay and then run the execution script.");
    }
}
