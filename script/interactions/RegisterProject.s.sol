// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";

/**
 * @title RegisterProjectScript
 * @dev A script to register a new project on the Azemora platform.
 * It demonstrates the first step in the project lifecycle.
 */
contract RegisterProjectScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        // Load the address of the deployed ProjectRegistry from the .env file
        address projectRegistryAddress = vm.envAddress("PROJECT_REGISTRY_ADDRESS");
        if (projectRegistryAddress == address(0)) {
            revert("PROJECT_REGISTRY_ADDRESS not set in .env file");
        }

        // Load the deployer's private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // --- Prepare Project Data ---
        // --- MODIFICATION: Make the project name unique by appending the timestamp ---
        string memory uniqueSuffix = vm.toString(block.timestamp);
        string memory projectName = string.concat("My Test Reforestation Project ", uniqueSuffix);
        bytes32 projectId = keccak256(abi.encodePacked(projectName));
        string memory metaURI = "ipfs://bafkreih2y7h2s6x5k5crvj3l3p5y6z4c6v2d7f4j3n2k1h4g5j6f7e8d9a";

        console.log("--- Registering a New Project ---");
        console.log("Registry Contract:", projectRegistryAddress);
        console.log("Project Name:", projectName);
        console.log("Generated Project ID:", vm.toString(projectId));
        console.log("Metadata URI:", metaURI);

        // Get an instance of the deployed ProjectRegistry contract
        ProjectRegistry projectRegistry = ProjectRegistry(projectRegistryAddress);

        // --- Execute Transaction ---
        vm.startBroadcast(deployerPrivateKey);

        projectRegistry.registerProject(projectId, metaURI);

        vm.stopBroadcast();

        console.log("\nProject registration transaction sent successfully!");
        console.log("Run the 'CheckProject.s.sol' script to verify its status.");
    }
}
