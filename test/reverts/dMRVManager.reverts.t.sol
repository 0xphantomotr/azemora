// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DMRVManagerRevertsTest is Test {
    ProjectRegistry registry;
    DMRVManager dmrvManager;
    DynamicImpactCredit credit;

    address admin = makeAddr("admin");
    address projectDeveloper = makeAddr("projectDeveloper");
    address verifier = makeAddr("verifier");
    address oracle = makeAddr("oracle");
    address otherUser = makeAddr("otherUser");

    bytes32 activeProjectId = keccak256("Active Project");
    bytes32 pendingProjectId = keccak256("Pending Project");

    function setUp() public {
        vm.startPrank(admin);
        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // Deploy Credits
        DynamicImpactCredit creditImpl = new DynamicImpactCredit(address(registry));
        credit = DynamicImpactCredit(
            address(new ERC1967Proxy(address(creditImpl), abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://"))))
        );

        // Deploy dMRV Manager
        DMRVManager dmrvManagerImpl = new DMRVManager(address(registry), address(credit));
        dmrvManager =
            DMRVManager(address(new ERC1967Proxy(address(dmrvManagerImpl), abi.encodeCall(DMRVManager.initialize, ()))));

        // Grant roles
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dmrvManager));
        dmrvManager.grantRole(dmrvManager.ORACLE_ROLE(), oracle);
        vm.stopPrank();

        // Setup projects
        vm.prank(projectDeveloper);
        registry.registerProject(activeProjectId, "ipfs://active");
        vm.prank(projectDeveloper);
        registry.registerProject(pendingProjectId, "ipfs://pending");

        // Activate one project
        vm.prank(verifier);
        registry.setProjectStatus(activeProjectId, ProjectRegistry.ProjectStatus.Active);
    }

    // --- requestVerification ---

    function test_revert_requestVerification_projectNotActive() public {
        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        vm.prank(projectDeveloper);
        dmrvManager.requestVerification(pendingProjectId);
    }

    // --- fulfillVerification ---

    function test_revert_fulfillVerification_notOracle() public {
        bytes memory data = abi.encode(100, false, bytes32(0), "ipfs://data");
        bytes4 expectedError = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        vm.expectRevert(abi.encodeWithSelector(expectedError, otherUser, dmrvManager.ORACLE_ROLE()));
        vm.prank(otherUser);
        dmrvManager.fulfillVerification(bytes32(0), data);
    }

    function test_revert_fulfillVerification_requestNotFound() public {
        bytes memory data = abi.encode(100, false, bytes32(0), "ipfs://data");
        vm.expectRevert(DMRVManager__RequestNotFound.selector);
        vm.prank(oracle);
        dmrvManager.fulfillVerification(keccak256("non-existent"), data);
    }

    function test_revert_fulfillVerification_alreadyFulfilled() public {
        // Step 1: Create a valid request
        vm.prank(projectDeveloper);
        bytes32 requestId = dmrvManager.requestVerification(activeProjectId);

        // Step 2: Fulfill it
        bytes memory data = abi.encode(100, false, bytes32(0), "ipfs://data");
        vm.prank(oracle);
        dmrvManager.fulfillVerification(requestId, data);

        // Step 3: Try to fulfill it again
        vm.expectRevert(DMRVManager__RequestAlreadyFulfilled.selector);
        vm.prank(oracle);
        dmrvManager.fulfillVerification(requestId, data);
    }

    // --- adminSubmitVerification ---

    function test_revert_adminSubmitVerification_notAdmin() public {
        bytes4 expectedError = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        vm.expectRevert(abi.encodeWithSelector(expectedError, otherUser, dmrvManager.DEFAULT_ADMIN_ROLE()));
        vm.prank(otherUser);
        dmrvManager.adminSubmitVerification(activeProjectId, 100, "ipfs://admin", false);
    }

    function test_revert_adminSubmitVerification_projectNotActive() public {
        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        vm.prank(admin);
        dmrvManager.adminSubmitVerification(pendingProjectId, 100, "ipfs://admin", false);
    }

    // --- Pausable ---

    function test_revert_whenPaused() public {
        vm.prank(admin);
        dmrvManager.pause();

        vm.expectRevert(bytes("EnforcedPause()"));
        vm.prank(projectDeveloper);
        dmrvManager.requestVerification(activeProjectId);
    }
}
