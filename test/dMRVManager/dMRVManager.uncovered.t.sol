// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/ProjectRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/MethodologyRegistry.sol";
import "../mocks/MockVerifierModule.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DMRVManagerUncovered is Test {
    DMRVManager dMRVManager;
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    MockVerifierModule mockModule;
    MethodologyRegistry methodologyRegistry;

    address admin = address(0xA11CE);
    address user = address(0xDEADBEEF);
    address projectOwner = address(0x044E);

    bytes32 public constant MOCK_MODULE_TYPE = keccak256("mock");
    bytes32 projectId = keccak256("Test Project");

    function setUp() public {
        // The test contract (address(this)) is now the deployer and initial admin.

        // --- Registry Setup ---
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(new ProjectRegistry()), abi.encodeCall(ProjectRegistry.initialize, ())))
        );

        // --- Credit Setup ---
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(new DynamicImpactCredit()),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://..."))
                )
            )
        );

        // --- MethodologyRegistry Setup ---
        methodologyRegistry = MethodologyRegistry(
            address(
                new ERC1967Proxy(
                    address(new MethodologyRegistry()), abi.encodeCall(MethodologyRegistry.initialize, (address(this)))
                )
            )
        );

        // --- dMRVManager Setup ---
        dMRVManager = DMRVManager(
            address(
                new ERC1967Proxy(
                    address(new DMRVManager()),
                    abi.encodeCall(
                        DMRVManager.initializeDMRVManager,
                        (address(registry), address(credit), address(methodologyRegistry))
                    )
                )
            )
        );

        // --- Role Setup ---
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(dMRVManager));
        registry.grantRole(registry.VERIFIER_ROLE(), admin);
        methodologyRegistry.grantRole(methodologyRegistry.DEFAULT_ADMIN_ROLE(), admin);
        methodologyRegistry.grantRole(methodologyRegistry.METHODOLOGY_ADMIN_ROLE(), admin);
        dMRVManager.grantRole(dMRVManager.DEFAULT_ADMIN_ROLE(), admin);
        dMRVManager.grantRole(dMRVManager.PAUSER_ROLE(), admin);
        dMRVManager.grantRole(dMRVManager.MODULE_ADMIN_ROLE(), admin);
        dMRVManager.grantRole(dMRVManager.REVERSER_ROLE(), admin);

        // --- Mock Module Setup ---
        mockModule = new MockVerifierModule();

        // --- Initial State ---
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
    }

    /* ---------- Uncovered Edge Cases ---------- */

    function test_FulfillVerification_CannotFulfillTwice() public {
        // Setup: Register module and request verification using the new flow
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

        bytes32 claimId = keccak256("claim-double-fulfill");
        uint256 requestedAmount = 100e18;
        vm.prank(user);
        dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence.json", requestedAmount, MOCK_MODULE_TYPE);
        bytes memory fulfillmentData = abi.encode(100, false, bytes32(0), "ipfs://new-metadata.json");

        // Fulfill once successfully
        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(projectId, claimId, fulfillmentData);

        // Try to fulfill again, expecting our new error
        vm.prank(address(mockModule));
        vm.expectRevert(DMRVManager__ClaimNotFoundOrAlreadyFulfilled.selector);
        dMRVManager.fulfillVerification(projectId, claimId, fulfillmentData);
    }

    function test_GetModuleForClaim() public {
        // Setup using the new flow
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

        bytes32 claimId = keccak256("claim-get-module");
        uint256 requestedAmount = 100e18;

        // Action
        vm.prank(user);
        dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence.json", requestedAmount, MOCK_MODULE_TYPE);

        // Assert
        assertEq(dMRVManager.getModuleForClaim(claimId), MOCK_MODULE_TYPE);
    }

    function test_AdminSubmitVerification_RevertsForInactiveProject() public {
        // Setup: Create an inactive project
        bytes32 inactiveProjectId = keccak256("Inactive Project");
        vm.prank(projectOwner);
        registry.registerProject(inactiveProjectId, "ipfs://inactive.json");

        // Action & Assert
        vm.prank(admin);
        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        dMRVManager.adminSubmitVerification(inactiveProjectId, 100, "ipfs://meta.json", false);
    }

    function test_Pause_RevertsForNonPauser() public {
        vm.startPrank(user); // Non-pauser
        bytes32 pauserRole = dMRVManager.PAUSER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), user, pauserRole
            )
        );
        dMRVManager.pause();
        vm.stopPrank();
    }

    function test_RevertsWhenPaused() public {
        vm.prank(admin);
        dMRVManager.pause();

        bytes4 expectedRevert = bytes4(keccak256("EnforcedPause()"));

        // Test requestVerification
        vm.prank(user);
        vm.expectRevert(expectedRevert);
        uint256 requestedAmount = 100e18;
        dMRVManager.requestVerification(projectId, keccak256("c1"), "uri", requestedAmount, MOCK_MODULE_TYPE);

        // Test fulfillVerification
        // Note: Can't test fulfill because request is blocked, so we test admin submit
        vm.prank(admin);
        vm.expectRevert(expectedRevert);
        dMRVManager.adminSubmitVerification(projectId, 1, "uri", false);
    }

    function test_GetRoles() public view {
        bytes32[] memory roles = dMRVManager.getRoles(admin);
        // Admin gets DEFAULT_ADMIN_ROLE, PAUSER_ROLE, REVERSER_ROLE, and MODULE_ADMIN_ROLE
        assertEq(roles.length, 4, "Admin should have 4 roles");

        bytes32[] memory emptyRoles = dMRVManager.getRoles(user);
        assertEq(emptyRoles.length, 0);
    }

    function test_requestVerification_and_fulfill() public {
        bytes32 localProjectId = keccak256("Project Alpha");
        bytes32 claimId = keccak256("Claim 001");
        string memory evidenceURI = "ipfs://evidence-for-alpha-1";
        uint256 requestedAmount = 100e18;

        // Register and activate project
        vm.prank(projectOwner);
        registry.registerProject(localProjectId, "ipfs://metadata");
        vm.prank(admin);
        registry.setProjectStatus(localProjectId, IProjectRegistry.ProjectStatus.Active);

        // --- FIX: Register the module first ---
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

        // Request verification
        vm.prank(projectOwner);
        dMRVManager.requestVerification(localProjectId, claimId, evidenceURI, requestedAmount, MOCK_MODULE_TYPE);

        // Fulfill verification
        string memory credentialCID = "ipfs://final-cid-alpha-1";
        bytes memory data = abi.encode(50, false, bytes32(0), credentialCID); // 50% outcome

        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(localProjectId, claimId, data);

        assertEq(
            credit.balanceOf(projectOwner, uint256(localProjectId)),
            (requestedAmount * 50) / 100,
            "Credits were not minted correctly"
        );
    }

    function test_fulfill_reverts_if_claim_not_found() public {
        bytes32 claimId = keccak256("c1");

        // DONT request verification, so claim is not found
        // dMRVManager.requestVerification(localProjectId, claimId, "ipfs://evidence.json", requestedAmount, MOCK_MODULE_TYPE);

        bytes memory data = abi.encode(100, false, bytes32(0), "cid");

        vm.prank(address(mockModule));
        vm.expectRevert(DMRVManager__ClaimNotFoundOrAlreadyFulfilled.selector);
        dMRVManager.fulfillVerification(projectId, claimId, data);
    }

    function test_fulfill_reverts_if_already_fulfilled() public {
        // --- FIX: Register the module first ---
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

        bytes32 claimId = keccak256("c1");
        uint256 requestedAmount = 100e18;

        vm.prank(projectOwner);
        // --- FIX: Use the globally activated projectId ---
        dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence.json", requestedAmount, MOCK_MODULE_TYPE);

        bytes memory data = abi.encode(100, false, bytes32(0), "cid");

        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(projectId, claimId, data);

        // Try to fulfill again
        vm.prank(address(mockModule));
        vm.expectRevert(DMRVManager__ClaimNotFoundOrAlreadyFulfilled.selector);
        dMRVManager.fulfillVerification(projectId, claimId, data);
    }

    function test_register_module_reverts_if_not_admin() public {
        // ARRANGE: A methodology must be valid *before* we can test the access control on adding it.
        // This makes the test more specific and robust by isolating the access control check.
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);

        // --- Defensive Check ---
        // Explicitly ensure the test condition is correct: projectOwner should NOT have the admin role.
        bytes32 moduleAdminRole = dMRVManager.MODULE_ADMIN_ROLE();
        assertFalse(
            dMRVManager.hasRole(moduleAdminRole, projectOwner),
            "Pre-condition failed: projectOwner should not have MODULE_ADMIN_ROLE"
        );

        // ACT & ASSERT: Now, try to add the *valid* module as a non-admin.
        // The only reason this should fail is the access control check.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), projectOwner, moduleAdminRole
            )
        );
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);
    }

    function test_register_reverts_if_methodology_not_valid() public {
        bytes32 invalidMethodology = keccak256("invalid");
        vm.prank(admin);
        vm.expectRevert(DMRVManager__MethodologyNotValid.selector);
        dMRVManager.addVerifierModule(invalidMethodology);
    }

    function test_requestVerification_reverts_when_paused() public {
        vm.prank(admin);
        dMRVManager.pause();

        vm.prank(projectOwner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        dMRVManager.requestVerification(keccak256("p1"), keccak256("c1"), "uri", 100e18, MOCK_MODULE_TYPE);
    }
}
