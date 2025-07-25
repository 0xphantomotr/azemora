// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";

/**
 * @title ProposeGrantRoleScript
 * @dev A script to create a governance proposal to grant the VERIFIER_ROLE.
 */
contract ProposeGrantRoleScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address projectRegistryAddress = vm.envAddress("PROJECT_REGISTRY_ADDRESS");
        uint256 proposerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proposerAddress = vm.addr(proposerPrivateKey);
        uint256 verifierPrivateKey = vm.envUint("VERIFIER_PRIVATE_KEY");
        address verifierAddress = vm.addr(verifierPrivateKey);

        // --- Build Proposal ---
        bytes32 verifierRole = ProjectRegistry(projectRegistryAddress).VERIFIER_ROLE();

        address[] memory targets = new address[](1);
        targets[0] = projectRegistryAddress;

        uint256[] memory values = new uint256[](1); // 0 ETH

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeWithSelector(bytes4(keccak256("grantRole(bytes32,address)")), verifierRole, verifierAddress);

        string memory description =
            string(abi.encodePacked("Proposal: Grant VERIFIER_ROLE to ", vm.toString(verifierAddress)));

        console.log("--- Creating Governance Proposal ---");
        console.log("Governor Contract:", governorAddress);
        console.log("Proposer:", proposerAddress);
        console.log("Target Contract (ProjectRegistry):", targets[0]);
        console.log("Role to Grant:", vm.toString(verifierRole));
        console.log("Recipient:", verifierAddress);
        console.log("Description:", description);

        // --- Execute Transaction ---
        vm.startBroadcast(proposerPrivateKey);

        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.stopBroadcast();

        console.log("\nProposal created successfully!");
        console.log("Proposal ID:", proposalId);
        console.log("You can now vote on this proposal using the Vote.s.sol script.");
    }
}
