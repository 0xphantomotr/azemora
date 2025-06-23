// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../mocks/MockVerifierModule.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DMRVManagerTest is Test {
    DMRVManager dMRVManager;
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    MockVerifierModule mockModule;

    address admin = address(0xA11CE);
    address moduleAdmin = address(0xBADF00D);
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

        // --- dMRVManager Setup ---
        DMRVManager dMRVManagerImpl = new DMRVManager();
        bytes memory dMRVManagerInitData =
            abi.encodeCall(DMRVManager.initializeDMRVManager, (address(registry), address(credit)));
        ERC1967Proxy dMRVManagerProxy = new ERC1967Proxy(address(dMRVManagerImpl), dMRVManagerInitData);
        dMRVManager = DMRVManager(address(dMRVManagerProxy));

        // --- Mock Module Setup ---
        mockModule = new MockVerifierModule();

        // --- Role Setup ---
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));
        dMRVManager.grantRole(dMRVManager.MODULE_ADMIN_ROLE(), moduleAdmin);

        vm.stopPrank();

        // --- Initial State ---
        // Register and approve a project
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
    }

    /*//////////////////////////////////////////////////////////////
                           MODULE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_RegisterModule() public {
        vm.prank(moduleAdmin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));

        assertEq(dMRVManager.verifierModules(MOCK_MODULE_TYPE), address(mockModule));
    }

    function test_RegisterModule_RevertsForNonAdmin() public {
        vm.startPrank(user); // Not a module admin
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                user,
                dMRVManager.MODULE_ADMIN_ROLE()
            )
        );
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
        vm.stopPrank();
    }

    function test_RegisterModule_RevertsForZeroAddress() public {
        vm.prank(moduleAdmin);
        vm.expectRevert(DMRVManager__ZeroAddress.selector);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(0));
    }

    function test_RegisterModule_RevertsIfAlreadyRegistered() public {
        vm.prank(moduleAdmin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));

        vm.prank(moduleAdmin);
        vm.expectRevert(abi.encodeWithSelector(DMRVManager__ModuleAlreadyRegistered.selector, MOCK_MODULE_TYPE));
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
    }

    function test_RemoveModule() public {
        vm.startPrank(moduleAdmin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
        dMRVManager.removeVerifierModule(MOCK_MODULE_TYPE);
        vm.stopPrank();

        assertEq(dMRVManager.verifierModules(MOCK_MODULE_TYPE), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          VERIFICATION FLOW
    //////////////////////////////////////////////////////////////*/

    function test_RequestVerification() public {
        // Register module first
        vm.prank(moduleAdmin);
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
        vm.prank(moduleAdmin);
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
        vm.prank(moduleAdmin);
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
        vm.prank(moduleAdmin);
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
