// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

contract DynamicImpactCreditFuzzTest is Test {
    DynamicImpactCredit credit;
    ProjectRegistry registry;
    address admin = address(0xA11CE);
    address dmrvManager = address(0xB01D);
    address user = address(0xCAFE);
    address verifier = address(0xC1E4);

    function setUp() public {
        vm.startPrank(admin);
        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        // Deploy Credit Contract
        DynamicImpactCredit impl = new DynamicImpactCredit();
        bytes memory initData = abi.encodeCall(
            DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://contract-metadata.json")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        credit = DynamicImpactCredit(address(proxy));

        // Grant roles
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), dmrvManager);
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), admin);
        vm.stopPrank();

        // Register and activate a project for fuzzing
        bytes32 fuzzProjectId = keccak256("Fuzz-Project");
        vm.startPrank(user);
        registry.registerProject(fuzzProjectId, "fuzz.json");
        vm.stopPrank();

        vm.startPrank(verifier);
        registry.setProjectStatus(fuzzProjectId, IProjectRegistry.ProjectStatus.Active);
        vm.stopPrank();
    }

    // Fuzz test: Retirement with random amounts
    function testFuzz_Retire(uint256 seed, uint256 mintAmount, uint256 retireAmount) public {
        bytes32 projectId = keccak256(abi.encode(seed));
        // Constrain values to reasonable ranges
        mintAmount = bound(mintAmount, 1, 1000000);
        retireAmount = bound(retireAmount, 1, mintAmount);

        // Register and activate project
        vm.prank(user);
        registry.registerProject(projectId, "meta.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);

        // Mint the tokens
        vm.prank(dmrvManager);
        credit.mintCredits(user, projectId, mintAmount, string(abi.encodePacked("ipfs://token", vm.toString(seed))));

        // Retire some tokens
        vm.prank(user);
        credit.retire(user, projectId, retireAmount);

        // Verify the remaining balance
        assertEq(credit.balanceOf(user, uint256(projectId)), mintAmount - retireAmount);
    }

    // Fuzz test: URI updates with random strings
    function testFuzz_CIDUpdates(uint256 seed, string calldata initialCID, string calldata updatedCID) public {
        bytes32 projectId = keccak256(abi.encode(seed));
        // Constrain CIDs to be non-empty
        vm.assume(bytes(initialCID).length > 0 && bytes(updatedCID).length > 0);
        vm.assume(bytes(initialCID).length < 200 && bytes(updatedCID).length < 200);

        // Register and activate project
        vm.prank(user);
        registry.registerProject(projectId, "meta.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);

        // Mint with initial CID
        vm.prank(dmrvManager);
        credit.mintCredits(user, projectId, 100, initialCID);

        // Update CID
        vm.prank(admin);
        credit.updateCredentialCID(projectId, updatedCID);

        // Verify the CID was updated
        assertEq(credit.uri(uint256(projectId)), updatedCID);

        // Verify history
        string[] memory history = credit.getCredentialCIDHistory(uint256(projectId));
        assertEq(history.length, 2, "History length should be 2");
        assertEq(history[0], initialCID, "Initial CID mismatch in history");
        assertEq(history[1], updatedCID, "Updated CID mismatch in history");
    }
}
