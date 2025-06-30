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

contract DMRVManagerTest is Test {
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

    // --- Events mirroring dMRVManager for testing ---
    event VerificationDelegated(
        bytes32 indexed claimId, bytes32 indexed projectId, bytes32 indexed moduleType, address moduleAddress
    );
    event VerificationFulfilled(bytes32 indexed claimId, bytes32 indexed projectId, bytes data);

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

        // --- MethodologyRegistry Setup (New) ---
        // Initialize with the test contract as the admin.
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
                    abi.encodeCall(DMRVManager.initializeDMRVManager, (address(registry), address(credit)))
                )
            )
        );
        // Link dMRVManager to the MethodologyRegistry.
        // The caller (this) is admin on dMRVManager by default from its initializer.
        dMRVManager.setMethodologyRegistry(address(methodologyRegistry));

        // --- Mock Module Setup ---
        mockModule = new MockVerifierModule();

        // --- Role Setup ---
        // Grant roles from the test contract (the admin) to the necessary accounts.
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(dMRVManager));
        dMRVManager.grantRole(dMRVManager.MODULE_ADMIN_ROLE(), admin);

        // Grant roles to the `admin` account that will be used inside the tests.
        registry.grantRole(registry.VERIFIER_ROLE(), admin);
        methodologyRegistry.grantRole(methodologyRegistry.DEFAULT_ADMIN_ROLE(), admin);
        methodologyRegistry.grantRole(methodologyRegistry.METHODOLOGY_ADMIN_ROLE(), admin);

        // --- Initial State ---
        // Use pranks for specific actions by other accounts.
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
    }

    /*//////////////////////////////////////////////////////////////
                           MODULE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_RegisterVerifierModule() public {
        // The new flow:
        // 1. Admin adds the methodology to the registry
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));

        // 2. Admin (DAO) approves it
        vm.prank(admin);
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);

        // 3. Anyone can now sync it to the dMRVManager
        vm.prank(admin); // Note: can be called by any address
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));

        assertEq(dMRVManager.verifierModules(MOCK_MODULE_TYPE), address(mockModule));
    }

    function test_RegisterVerifierModule_RevertsIfUnapproved() public {
        // 1. Admin adds the methodology but does NOT approve it
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));

        // 2. Attempt to register fails
        vm.prank(admin);
        vm.expectRevert(DMRVManager__MethodologyNotValid.selector);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
    }

    function test_RegisterVerifierModule_RevertsIfAlreadyRegistered() public {
        // Full, correct registration flow
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        vm.prank(admin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));

        // Attempt to register again
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DMRVManager__ModuleAlreadyRegistered.selector, MOCK_MODULE_TYPE));
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
    }

    /*//////////////////////////////////////////////////////////////
                          VERIFICATION FLOW
    //////////////////////////////////////////////////////////////*/

    function test_RequestVerification() public {
        // Setup: Register module first via new flow
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));

        // Delegate as user
        vm.prank(user);
        bytes32 claimId = keccak256("claim-001");
        string memory evidenceURI = "ipfs://evidence.json";

        vm.expectEmit(true, true, true, true);
        emit VerificationDelegated(claimId, projectId, MOCK_MODULE_TYPE, address(mockModule));
        dMRVManager.requestVerification(projectId, claimId, evidenceURI, MOCK_MODULE_TYPE);
    }

    function test_RequestVerification_RevertsForUnregisteredModule() public {
        vm.prank(user);
        vm.expectRevert(DMRVManager__ModuleNotRegistered.selector);
        dMRVManager.requestVerification(projectId, keccak256("claim-001"), "ipfs://evidence.json", MOCK_MODULE_TYPE);
    }

    function test_RequestVerification_RevertsForInactiveProject() public {
        // Create a new project but don't activate it
        bytes32 pendingProjectId = keccak256("Pending Project");
        vm.prank(projectOwner);
        registry.registerProject(pendingProjectId, "ipfs://pending.json");

        // Register module
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));

        // Attempt to delegate
        vm.prank(user);
        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        dMRVManager.requestVerification(
            pendingProjectId, keccak256("claim-001"), "ipfs://evidence.json", MOCK_MODULE_TYPE
        );
    }

    function test_FulfillVerification() public {
        // Register module and request verification
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));

        bytes32 claimId = keccak256("claim-123");
        vm.prank(user);
        dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence.json", MOCK_MODULE_TYPE);

        // The module "calls back" to fulfill
        bytes memory fulfillmentData = abi.encode(100e18, false, bytes32(0), "ipfs://new-metadata.json");

        vm.prank(address(mockModule));
        vm.expectEmit(true, true, true, true);
        emit VerificationFulfilled(claimId, projectId, fulfillmentData);
        dMRVManager.fulfillVerification(projectId, claimId, fulfillmentData);

        // Check if credits were minted
        assertEq(credit.balanceOf(projectOwner, uint256(projectId)), 100e18);
    }

    function test_FulfillVerification_RevertsIfNotModule() public {
        // 1. Register module
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));

        // 2. Request verification to create a valid claim
        bytes32 claimId = keccak256("claim-123");
        vm.prank(user);
        dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence.json", MOCK_MODULE_TYPE);

        // 3. Attempt to fulfill from an unauthorized address
        bytes memory fulfillmentData = abi.encode(100e18, true, bytes32(0), "ipfs://new-metadata.json");

        vm.prank(user); // A random user cannot fulfill
        vm.expectRevert(DMRVManager__CallerNotRegisteredModule.selector);
        dMRVManager.fulfillVerification(projectId, claimId, fulfillmentData);
    }
}
