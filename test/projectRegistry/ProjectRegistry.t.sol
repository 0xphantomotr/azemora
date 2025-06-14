// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProjectRegistryTest is Test {
    ProjectRegistry registry;

    address admin = address(0xA11CE);
    address verifier = address(0xC1E4);
    address projectOwner = address(0x044E);
    address anotherUser = address(0xBEEF);

    bytes32 projectId = keccak256("Test Project");

    function setUp() public {
        vm.startPrank(admin);
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = ProjectRegistry(address(registryProxy));

        // Grant verifier role
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        vm.stopPrank();

        // Register a project for testing state-changing functions
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");
    }

    /* ----------------- */
    /*     Registration  */
    /* ----------------- */

    function test_Register_WritesStructAndEmitsEvent() public {
        bytes32 newId = keccak256("New Project");
        string memory uri = "ipfs://new.json";

        vm.prank(anotherUser);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ProjectRegistry.ProjectRegistered(newId, anotherUser, uri);
        registry.registerProject(newId, uri);

        ProjectRegistry.Project memory project = registry.getProject(newId);
        assertEq(project.id, newId);
        assertEq(project.owner, anotherUser);
        assertEq(uint8(project.status), uint8(ProjectRegistry.ProjectStatus.Pending));
        assertEq(project.metaURI, uri);
    }

    function test_Register_RevertsOnDuplicateId() public {
        vm.prank(anotherUser);
        vm.expectRevert(ProjectRegistry__IdAlreadyExists.selector);
        registry.registerProject(projectId, "ipfs://duplicate.json");
    }

    /* ----------------- */
    /*    Status Changes */
    /* ----------------- */

    function test_SetStatus_VerifierCanApprove() public {
        vm.prank(verifier);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ProjectRegistry.ProjectStatusChanged(
            projectId, ProjectRegistry.ProjectStatus.Pending, ProjectRegistry.ProjectStatus.Active
        );
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        assertTrue(registry.isProjectActive(projectId));
    }

    function test_SetStatus_AdminCanPauseAndArchive() public {
        // First, activate the project
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        // Then, admin can pause it
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ProjectRegistry.ProjectStatusChanged(
            projectId, ProjectRegistry.ProjectStatus.Active, ProjectRegistry.ProjectStatus.Paused
        );
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Paused);
        assertEq(uint8(registry.getProject(projectId).status), uint8(ProjectRegistry.ProjectStatus.Paused));

        // And admin can archive it
        vm.expectEmit(true, true, true, true, address(registry));
        emit ProjectRegistry.ProjectStatusChanged(
            projectId, ProjectRegistry.ProjectStatus.Paused, ProjectRegistry.ProjectStatus.Archived
        );
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Archived);
        vm.stopPrank();

        assertEq(uint8(registry.getProject(projectId).status), uint8(ProjectRegistry.ProjectStatus.Archived));
        assertFalse(registry.isProjectActive(projectId));
    }

    function test_SetStatus_RevertsForNonVerifier() public {
        vm.prank(anotherUser);
        vm.expectRevert(ProjectRegistry__CallerNotVerifier.selector);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
    }

    function test_SetStatus_RevertsForNonAdmin() public {
        vm.prank(anotherUser);
        vm.expectRevert(ProjectRegistry__CallerNotAdmin.selector);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Paused);

        vm.expectRevert(ProjectRegistry__CallerNotAdmin.selector);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Archived);
    }

    function test_SetStatus_RevertsOnInvalidTransition() public {
        // an already pending project cannot be set to pending again
        vm.prank(admin);
        vm.expectRevert(ProjectRegistry__StatusIsSame.selector);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Pending);
    }

    function test_SetStatus_RevertsOnArchivedProject() public {
        // first, archive it
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Archived);

        // then, try to change it
        vm.prank(admin);
        vm.expectRevert(ProjectRegistry__ArchivedProjectCannotBeModified.selector);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Paused);
    }

    function test_SetStatus_RevertsOnNonExistentProject() public {
        vm.prank(verifier);
        vm.expectRevert(ProjectRegistry__ProjectNotFound.selector);
        registry.setProjectStatus(bytes32(uint256(420)), ProjectRegistry.ProjectStatus.Active);
    }

    function test_SetStatus_RevertsOnInvalidTransitionToPaused() public {
        // cannot pause from pending
        vm.prank(admin);
        vm.expectRevert(ProjectRegistry__InvalidPauseState.selector);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Paused);
    }

    function test_SetStatus_RevertsOnInvalidTransitionToPending() public {
        // cannot transition to pending from any other state
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        vm.prank(admin);
        vm.expectRevert(ProjectRegistry__InvalidStatusTransition.selector);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Pending);
    }

    /* ----------------- */
    /*     Ownership     */
    /* ----------------- */

    function test_SetProjectMetaURI_OnlyOwnerCanUpdate() public {
        string memory newURI = "ipfs://updated.json";

        // Owner should succeed
        vm.prank(projectOwner);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ProjectRegistry.ProjectMetaURIUpdated(projectId, newURI);
        registry.setProjectMetaURI(projectId, newURI);
        assertEq(registry.getProject(projectId).metaURI, newURI);

        // Others should fail
        vm.prank(anotherUser);
        vm.expectRevert(ProjectRegistry__NotProjectOwner.selector);
        registry.setProjectMetaURI(projectId, "ipfs://fail.json");
    }

    function test_TransferProjectOwnership_OnlyOwnerCanTransfer() public {
        // Owner should succeed
        vm.prank(projectOwner);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ProjectRegistry.ProjectOwnershipTransferred(projectId, projectOwner, anotherUser);
        registry.transferProjectOwnership(projectId, anotherUser);
        assertEq(registry.getProject(projectId).owner, anotherUser);

        // Old owner should fail
        vm.prank(projectOwner);
        vm.expectRevert(ProjectRegistry__NotProjectOwner.selector);
        registry.transferProjectOwnership(projectId, admin);
    }

    function test_TransferProjectOwnership_RevertsOnZeroAddress() public {
        vm.prank(projectOwner);
        vm.expectRevert(ProjectRegistry__NewOwnerIsZeroAddress.selector);
        registry.transferProjectOwnership(projectId, address(0));
    }

    function test_Fuzz_AccessControls(address caller, address newOwner, string calldata uri) public {
        vm.assume(caller != projectOwner);
        vm.assume(caller != admin);
        vm.assume(caller != verifier);

        // Test setProjectMetaURI
        vm.prank(caller);
        vm.expectRevert(ProjectRegistry__NotProjectOwner.selector);
        registry.setProjectMetaURI(projectId, uri);

        // Test transferProjectOwnership
        vm.prank(caller);
        vm.expectRevert(ProjectRegistry__NotProjectOwner.selector);
        registry.transferProjectOwnership(projectId, newOwner);
    }

    /* ----------------- */
    /*      Pausable     */
    /* ----------------- */

    function test_PauseAndUnpause() public {
        bytes32 pauserRole = registry.PAUSER_ROLE();

        vm.startPrank(admin);
        // Admin has pauser role by default from setUp
        registry.pause();
        assertTrue(registry.paused());
        registry.unpause();
        assertFalse(registry.paused());
        vm.stopPrank();

        // Non-pauser cannot pause
        vm.prank(anotherUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), anotherUser, pauserRole
            )
        );
        registry.pause();
    }

    function test_RevertsWhenPaused() public {
        vm.prank(admin);
        registry.pause();

        // Check key functions revert when paused
        bytes4 expectedRevert = bytes4(keccak256("EnforcedPause()"));

        vm.prank(anotherUser);
        vm.expectRevert(expectedRevert);
        registry.registerProject(keccak256("paused project"), "ipfs://paused.json");

        vm.prank(verifier);
        vm.expectRevert(expectedRevert);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.prank(projectOwner);
        vm.expectRevert(expectedRevert);
        registry.setProjectMetaURI(projectId, "ipfs://paused.json");

        vm.prank(projectOwner);
        vm.expectRevert(expectedRevert);
        registry.transferProjectOwnership(projectId, anotherUser);
    }

    /* ----------------- */
    /*      View         */
    /* ----------------- */
    function test_GetProject_RevertsOnNonExistentProject() public {
        vm.expectRevert(ProjectRegistry__ProjectNotFound.selector);
        registry.getProject(keccak256("non existent"));
    }
}
