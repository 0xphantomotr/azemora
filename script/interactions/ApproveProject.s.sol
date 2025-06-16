// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";

/**
 * @title ApproveProjectScript
 * @dev A script to change a project's status from 'Pending' to 'Active'.
 * This is a privileged action that requires the VERIFIER_ROLE.
 */
contract ApproveProjectScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        address projectRegistryAddress = vm.envAddress("PROJECT_REGISTRY_ADDRESS");
        if (projectRegistryAddress == address(0)) {
            revert("PROJECT_REGISTRY_ADDRESS not set in .env file");
        }
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Prepare Project Data ---
        // Must be the same as in the registration script to get the correct ID.
        string memory projectName = "My Test Reforestation Project";
        bytes32 projectId = keccak256(abi.encodePacked(projectName));

        console.log("--- Approving Project ---");
        console.log("Registry Contract:", projectRegistryAddress);
        console.log("Project ID:", vm.toString(projectId));
        console.log("New Status: Active");

        ProjectRegistry projectRegistry = ProjectRegistry(projectRegistryAddress);

        // --- Execute Transaction ---
        vm.startBroadcast(deployerPrivateKey);

        projectRegistry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.stopBroadcast();

        console.log("\nProject approval transaction sent successfully!");
        console.log("You can run the 'CheckProject.s.sol' script again to see the updated status.");
    }
} 