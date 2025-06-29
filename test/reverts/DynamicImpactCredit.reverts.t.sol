// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

contract DynamicImpactCreditRevertsTest is Test {
    ProjectRegistry registry;
    DynamicImpactCredit credit;

    address admin = makeAddr("admin");
    address dmrvManager = makeAddr("dmrvManager");
    address metadataUpdater = makeAddr("metadataUpdater");
    address projectDeveloper = makeAddr("projectDeveloper");
    address otherUser = makeAddr("otherUser");

    bytes32 activeProjectId = keccak256("Active Project");
    uint256 activeTokenId = uint256(activeProjectId);
    bytes32 pendingProjectId = keccak256("Pending Project");

    function setUp() public {
        vm.startPrank(admin);
        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        // No verifier needed, we control status directly with admin for this test

        // Deploy Credits contract
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(creditImpl),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://"))
                )
            )
        );

        // Grant necessary roles
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), dmrvManager);
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), metadataUpdater);
        credit.grantRole(credit.PAUSER_ROLE(), admin);
        vm.stopPrank();

        // Setup a pending and an active project
        vm.prank(projectDeveloper);
        registry.registerProject(pendingProjectId, "ipfs://pending");
        vm.prank(projectDeveloper);
        registry.registerProject(activeProjectId, "ipfs://active");
        vm.prank(admin);
        registry.setProjectStatus(activeProjectId, IProjectRegistry.ProjectStatus.Active);
    }

    // --- mintCredits ---

    function test_revert_mintCredits_notDMRVManager() public {
        bytes4 expectedError = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        vm.expectRevert(abi.encodeWithSelector(expectedError, otherUser, credit.DMRV_MANAGER_ROLE()));
        vm.prank(otherUser);
        credit.mintCredits(projectDeveloper, activeProjectId, 100, "ipfs://data");
    }

    function test_revert_mintCredits_projectNotActive() public {
        vm.expectRevert(DynamicImpactCredit__ProjectNotActive.selector);
        vm.prank(dmrvManager);
        credit.mintCredits(projectDeveloper, pendingProjectId, 100, "ipfs://data");
    }

    // --- setTokenURI ---

    function test_revert_setTokenURI_notMetadataUpdater() public {
        // First mint a token so we can try to update its URI
        vm.prank(dmrvManager);
        credit.mintCredits(projectDeveloper, activeProjectId, 1, "ipfs://original");

        bytes4 expectedError = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        vm.expectRevert(abi.encodeWithSelector(expectedError, otherUser, credit.METADATA_UPDATER_ROLE()));
        vm.prank(otherUser);
        credit.updateCredentialCID(activeProjectId, "ipfs://new");
    }

    // --- uri ---

    function test_revert_uri_nonExistentToken() public {
        bytes4 expectedError = bytes4(keccak256("DynamicImpactCredit__CredentialNotSet()"));
        vm.expectRevert(expectedError);
        credit.uri(uint256(keccak256("non-existent")));
    }

    // --- retire ---

    function test_revert_retire_notOwnerOrApproved() public {
        // Mint tokens to the project developer
        vm.prank(dmrvManager);
        credit.mintCredits(projectDeveloper, activeProjectId, 100, "ipfs://data");

        // Try to retire them from another user's account
        vm.expectRevert(DynamicImpactCredit__NotAuthorized.selector);
        vm.prank(otherUser);
        credit.retire(projectDeveloper, activeProjectId, 50);
    }

    // --- Pausable ---

    function test_revert_whenPaused_mintCredits() public {
        vm.prank(admin);
        credit.pause();

        vm.expectRevert(bytes("EnforcedPause()"));
        vm.prank(dmrvManager);
        credit.mintCredits(projectDeveloper, activeProjectId, 100, "ipfs://paused.json");
    }
}
