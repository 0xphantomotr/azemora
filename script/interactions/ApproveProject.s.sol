// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

/**
 * @title ApproveProjectScript
 * @dev A script to approve a 'Pending' project, changing its status to 'Active'.
 * This script must be run by an account holding the VERIFIER_ROLE.
 */
contract ApproveProjectScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address projectRegistryAddress = vm.envAddress("PROJECT_REGISTRY_ADDRESS");
        if (projectRegistryAddress == address(0)) {
            revert("PROJECT_REGISTRY_ADDRESS not set in .env file");
        }

        uint256 verifierPrivateKey = vm.envUint("VERIFIER_PRIVATE_KEY");
        if (verifierPrivateKey == 0) {
            revert("VERIFIER_PRIVATE_KEY not set in .env file");
        }
        address verifierAddress = vm.addr(verifierPrivateKey);

        // --- Prepare Project Data ---
        // --- MODIFICATION: Hardcode the specific Project ID from the successful registration ---
        bytes32 projectId = 0x9ae32c048ebcac9031ac02cc0bfa46abc7ba897ebd5df4b96faede36d217bb13;

        console.log("--- Approving Project ---");
        console.log("Registry Contract:", projectRegistryAddress);
        console.log("Project ID:", vm.toString(projectId));
        console.log("Approver (Verifier):", verifierAddress);

        // Get an instance of the deployed ProjectRegistry contract
        ProjectRegistry projectRegistry = ProjectRegistry(projectRegistryAddress);

        // --- Execute Transaction ---
        vm.startBroadcast(verifierPrivateKey);
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        vm.stopBroadcast();

        console.log("\nTransaction broadcasted successfully!");
        console.log("Project has been set to 'Active'.");
    }
}
