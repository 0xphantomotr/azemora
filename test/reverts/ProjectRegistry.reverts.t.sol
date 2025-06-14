// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProjectRegistryRevertsTest is Test {
    ProjectRegistry registry;

    address admin = makeAddr("admin");
    address projectDeveloper = makeAddr("projectDeveloper");
    address verifier = makeAddr("verifier");
    address otherUser = makeAddr("otherUser");

    bytes32 projectId = keccak256("Test Project");

    function setUp() public {
        vm.startPrank(admin);
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        // Grant verifier role
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        vm.stopPrank();

        // Register a project to be used in other tests
        vm.prank(projectDeveloper);
        registry.registerProject(projectId, "ipfs://initial");
    }

    // --- registerProject ---

    function test_revert_registerProject_alreadyExists() public {
        vm.expectRevert(ProjectRegistry__IdAlreadyExists.selector);
        vm.prank(otherUser);
        registry.registerProject(projectId, "ipfs://duplicate");
    }

    // --- setProjectStatus ---

    function test_revert_setProjectStatus_nonExistentProject() public {
        vm.expectRevert(ProjectRegistry__ProjectNotFound.selector);
        vm.prank(verifier);
        registry.setProjectStatus(keccak256("non-existent"), ProjectRegistry.ProjectStatus.Active);
    }

    function test_revert_setProjectStatus_toActive_notVerifier() public {
        vm.expectRevert(ProjectRegistry__CallerNotVerifier.selector);
        vm.prank(otherUser);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
    }

    function test_revert_setProjectStatus_toPaused_notAdmin() public {
        vm.expectRevert(ProjectRegistry__CallerNotAdmin.selector);
        vm.prank(otherUser);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Paused);
    }

    function test_revert_setProjectStatus_toArchived_notAdmin() public {
        vm.expectRevert(ProjectRegistry__CallerNotAdmin.selector);
        vm.prank(otherUser);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Archived);
    }

    function test_revert_setProjectStatus_invalidTransition() public {
        // e.g., trying to set to Pending again from Pending
        vm.expectRevert(ProjectRegistry__StatusIsSame.selector);
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Pending);
    }

    // --- setProjectMetaURI ---

    function test_revert_setProjectMetaURI_notOwner() public {
        vm.expectRevert(ProjectRegistry__NotProjectOwner.selector);
        vm.prank(otherUser);
        registry.setProjectMetaURI(projectId, "ipfs://new-meta");
    }

    // --- transferProjectOwnership ---

    function test_revert_transferProjectOwnership_notOwner() public {
        vm.expectRevert(ProjectRegistry__NotProjectOwner.selector);
        vm.prank(otherUser);
        registry.transferProjectOwnership(projectId, otherUser);
    }

    function test_revert_transferProjectOwnership_toZeroAddress() public {
        vm.prank(projectDeveloper);
        vm.expectRevert(ProjectRegistry__NewOwnerIsZeroAddress.selector);
        registry.transferProjectOwnership(projectId, address(0));
    }

    function test_revert_setProjectStatus_toPending() public {
        // Activate the project first to have a valid starting state other than Pending.
        vm.startPrank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        vm.stopPrank();

        // Try to move it back to Pending, which is not a valid transition target.
        vm.prank(admin);
        vm.expectRevert(ProjectRegistry__InvalidStatusTransition.selector);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Pending);
    }
}
