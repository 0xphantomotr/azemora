// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

/**
 * @title CheckProjectScript
 * @dev A script to read the data of a registered project from the Azemora platform.
 */
contract CheckProjectScript is Script {
    function run() external view {
        // --- Load Environment Variables ---
        address projectRegistryAddress = vm.envAddress("PROJECT_REGISTRY_ADDRESS");
        if (projectRegistryAddress == address(0)) {
            revert("PROJECT_REGISTRY_ADDRESS not set in .env file");
        }

        // --- Prepare Project Data ---
        // We must use the *exact* same name as in the registration script to generate the same ID.
        string memory projectName = "My Test Reforestation Project";
        bytes32 projectId = keccak256(abi.encodePacked(projectName));

        console.log("--- Checking Project Status ---");
        console.log("Registry Contract:", projectRegistryAddress);
        console.log("Project ID:", vm.toString(projectId));

        // Get an instance of the deployed ProjectRegistry contract using its interface
        IProjectRegistry projectRegistry = IProjectRegistry(projectRegistryAddress);

        // --- Execute Read Call ---
        // No broadcast needed for view/pure functions.
        IProjectRegistry.Project memory project = projectRegistry.getProject(projectId);

        console.log("\n--- Project Data ---");
        console.log("ID:", vm.toString(project.id));
        console.log("Metadata URI:", project.metaURI);
        console.log("Owner:", project.owner);

        // Interpret the enum status for readability
        string memory statusString;
        if (project.status == IProjectRegistry.ProjectStatus.Pending) {
            statusString = "Pending (0)";
        } else if (project.status == IProjectRegistry.ProjectStatus.Active) {
            statusString = "Active (1)";
        } else if (project.status == IProjectRegistry.ProjectStatus.Paused) {
            statusString = "Paused (2)";
        } else if (project.status == IProjectRegistry.ProjectStatus.Archived) {
            statusString = "Archived (3)";
        } else {
            statusString = "Unknown";
        }
        console.log("Status:", statusString);

        if (project.status == IProjectRegistry.ProjectStatus.Pending) {
            console.log("\nNext Step: Run the 'ApproveProject.s.sol' script to activate the project.");
        }
    }
}
