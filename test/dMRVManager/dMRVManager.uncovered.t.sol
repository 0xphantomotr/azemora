// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/ProjectRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../mocks/MockVerifierModule.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DMRVManagerUncovered is Test {
    DMRVManager dMRVManager;
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    MockVerifierModule mockModule;

    address admin = address(0xA11CE);
    address user = address(0xDEADBEEF);
    address projectOwner = address(0x044E);

    bytes32 public constant MOCK_MODULE_TYPE = keccak256("mock");
    bytes32 projectId = keccak256("Test Project");

    function setUp() public {
        vm.startPrank(admin);
        // --- Registry Setup ---
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = ProjectRegistry(address(registryProxy));

        // --- Credit Setup ---
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        bytes memory creditInitData =
            abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://collection"));
        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));

        // --- dMRVManager Setup ---
        DMRVManager dMRVManagerImpl = new DMRVManager();
        bytes memory dMRVManagerInitData =
            abi.encodeCall(DMRVManager.initializeDMRVManager, (address(registry), address(credit)));
        ERC1967Proxy dMRVManagerProxy = new ERC1967Proxy(address(dMRVManagerImpl), dMRVManagerInitData);
        dMRVManager = DMRVManager(address(dMRVManagerProxy));

        // Grant role back to the proxy address
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(dMRVManager));
        dMRVManager.grantRole(dMRVManager.PAUSER_ROLE(), admin);

        // --- Mock Module Setup ---
        mockModule = new MockVerifierModule();

        vm.stopPrank();

        // --- Initial State ---
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
    }

    /* ---------- Uncovered Edge Cases ---------- */

    function test_FulfillVerification_CannotFulfillTwice() public {
        // Setup: Register module and request verification
        vm.prank(admin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
        bytes32 claimId = keccak256("claim-double-fulfill");
        vm.prank(user);
        dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence.json", MOCK_MODULE_TYPE);
        bytes memory fulfillmentData = abi.encode(100e18, false, bytes32(0), "ipfs://new-metadata.json");

        // Fulfill once successfully
        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(projectId, claimId, fulfillmentData);

        // Try to fulfill again, expecting our new error
        vm.prank(address(mockModule));
        vm.expectRevert(DMRVManager__ClaimNotFoundOrAlreadyFulfilled.selector);
        dMRVManager.fulfillVerification(projectId, claimId, fulfillmentData);
    }

    function test_GetModuleForClaim() public {
        // Setup
        vm.prank(admin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
        bytes32 claimId = keccak256("claim-get-module");

        // Action
        vm.prank(user);
        dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence.json", MOCK_MODULE_TYPE);

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
        dMRVManager.requestVerification(projectId, keccak256("c1"), "uri", MOCK_MODULE_TYPE);

        // Test fulfillVerification
        // Note: Can't test fulfill because request is blocked, so we test admin submit
        vm.prank(admin);
        vm.expectRevert(expectedRevert);
        dMRVManager.adminSubmitVerification(projectId, 1, "uri", false);
    }

    function test_GetRoles() public {
        bytes32[] memory roles = dMRVManager.getRoles(admin);
        // Admin gets DEFAULT_ADMIN_ROLE, MODULE_ADMIN_ROLE, PAUSER_ROLE
        assertEq(roles.length, 3);
        assertEq(roles[0], dMRVManager.DEFAULT_ADMIN_ROLE());
        assertEq(roles[1], dMRVManager.MODULE_ADMIN_ROLE());
        assertEq(roles[2], dMRVManager.PAUSER_ROLE());

        bytes32[] memory emptyRoles = dMRVManager.getRoles(user);
        assertEq(emptyRoles.length, 0);
    }
}
