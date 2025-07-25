// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";

/**
 * @title ExecuteGrantRoleScript
 * @dev A script to execute a queued proposal to grant the VERIFIER_ROLE.
 */
contract ExecuteGrantRoleScript is Script {
    function run() external {
        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address projectRegistryAddress = vm.envAddress("PROJECT_REGISTRY_ADDRESS");
        uint256 executorPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 verifierPrivateKey = vm.envUint("VERIFIER_PRIVATE_KEY");
        address verifierAddress = vm.addr(verifierPrivateKey);

        // --- Reconstruct Proposal Details EXACTLY as in the proposal script ---
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
