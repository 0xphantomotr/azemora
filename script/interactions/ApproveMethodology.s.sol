// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { MethodologyRegistry } from "../../src/core/MethodologyRegistry.sol";

contract ApproveMethodology is Script {
    function run() external {
        address methodologyRegistryAddress = vm.envAddress("METHODOLOGY_REGISTRY_ADDRESS");
        
        // The ID for the ReputationWeightedVerifier methodology
        bytes32 methodologyId = keccak256(bytes("ReputationWeightedVerifier_v2"));
        // The address of the deployed verifier module
        address moduleAddress = 0x17fcc81fBCab7835804bc4feb79CC83C25B493c0; // From transaction trace

        // --- CORRECTED ARGUMENTS ---
        string memory schemaURI = "ipfs://placeholder_for_methodology_doc";
        bytes32 schemaHash = keccak256(bytes(schemaURI));

        console.log("Approving methodology in the registry...");
        console.log(" -> Methodology ID:");
        console.logBytes32(methodologyId);

        vm.startBroadcast();

        // --- CORRECTED FUNCTION CALL ---
        // First, add the methodology to the registry with all required arguments
        MethodologyRegistry(methodologyRegistryAddress).addMethodology(
            methodologyId,
            moduleAddress,
            schemaURI,
            schemaHash
        );

        // Second, approve it (as the DAO would)
        MethodologyRegistry(methodologyRegistryAddress).approveMethodology(methodologyId);

        vm.stopBroadcast();

        console.log("Successfully approved the methodology.");
    }
} 