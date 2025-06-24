// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../mocks/MockVerifierModule.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

contract DMRVManagerRevertsTest is Test {
    ProjectRegistry registry;
    DMRVManager dMRVManager;
    DynamicImpactCredit credit;
    MockVerifierModule mockModule;

    address admin = makeAddr("admin");
    address projectDeveloper = makeAddr("projectDeveloper");
    address verifier = makeAddr("verifier");
    address otherUser = makeAddr("otherUser");

    bytes32 activeProjectId = keccak256("Active Project");
    bytes32 pendingProjectId = keccak256("Pending Project");
    bytes32 public constant MOCK_MODULE_TYPE = keccak256("mock");

    function setUp() public {
        vm.startPrank(admin);
        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // Deploy Credits
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(creditImpl),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://"))
                )
            )
        );

        // Deploy dMRV Manager
        DMRVManager dMRVManagerImpl = new DMRVManager();
        dMRVManager = DMRVManager(
            address(
                new ERC1967Proxy(
                    address(dMRVManagerImpl),
                    abi.encodeCall(DMRVManager.initializeDMRVManager, (address(registry), address(credit)))
                )
            )
        );

        mockModule = new MockVerifierModule();

        // Grant roles
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(dMRVManager));
        dMRVManager.grantRole(dMRVManager.MODULE_ADMIN_ROLE(), admin);
        vm.stopPrank();

        // Setup projects
        vm.prank(projectDeveloper);
        registry.registerProject(activeProjectId, "ipfs://active");
        vm.prank(projectDeveloper);
        registry.registerProject(pendingProjectId, "ipfs://pending");

        // Activate one project
        vm.prank(verifier);
        registry.setProjectStatus(activeProjectId, IProjectRegistry.ProjectStatus.Active);
    }

    // --- requestVerification ---

    function test_revert_requestVerification_projectNotActive() public {
        vm.prank(admin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        vm.prank(projectDeveloper);
        dMRVManager.requestVerification(pendingProjectId, keccak256("claim"), "uri", MOCK_MODULE_TYPE);
    }

    // --- fulfillVerification ---

    function test_revert_fulfillVerification_notRegisteredModule() public {
        // Step 1: Register two different modules
        MockVerifierModule otherModule = new MockVerifierModule();
        vm.startPrank(admin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
        dMRVManager.registerVerifierModule(keccak256("OTHER_MODULE"), address(otherModule));
        vm.stopPrank();

        // Step 2: Create a valid request with the main module
        bytes32 claimId = keccak256("claim-to-fail");
        vm.prank(projectDeveloper);
        dMRVManager.requestVerification(activeProjectId, claimId, "uri", MOCK_MODULE_TYPE);

        // Step 3: Attempt to fulfill from the wrong module
        bytes memory data = abi.encode(100, false, bytes32(0), "ipfs://data");
        vm.prank(address(otherModule)); // Prank as the wrong module
        vm.expectRevert(DMRVManager__CallerNotRegisteredModule.selector);
        dMRVManager.fulfillVerification(activeProjectId, claimId, data);
    }

    function test_revert_fulfillVerification_claimNotFound() public {
        vm.prank(admin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
        bytes memory data = abi.encode(100, false, bytes32(0), "ipfs://data");
        vm.expectRevert(DMRVManager__ClaimNotFoundOrAlreadyFulfilled.selector);
        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(activeProjectId, keccak256("non-existent"), data);
    }

    function test_revert_fulfillVerification_alreadyFulfilled() public {
        // Step 1: Create a valid request
        vm.prank(admin);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE, address(mockModule));
        vm.prank(projectDeveloper);
        bytes32 claimId = keccak256("my-claim");
        dMRVManager.requestVerification(activeProjectId, claimId, "uri", MOCK_MODULE_TYPE);

        // Step 2: Fulfill it
        bytes memory data = abi.encode(100, false, bytes32(0), "ipfs://data");
        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(activeProjectId, claimId, data);

        // Step 3: Try to fulfill it again
        vm.expectRevert(DMRVManager__ClaimNotFoundOrAlreadyFulfilled.selector);
        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(activeProjectId, claimId, data);
    }

    // --- adminSubmitVerification ---

    function test_revert_adminSubmitVerification_notAdmin() public {
        bytes4 expectedError = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        vm.expectRevert(abi.encodeWithSelector(expectedError, otherUser, dMRVManager.DEFAULT_ADMIN_ROLE()));
        vm.prank(otherUser);
        dMRVManager.adminSubmitVerification(activeProjectId, 100, "ipfs://admin", false);
    }

    function test_revert_adminSubmitVerification_projectNotActive() public {
        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        vm.prank(admin);
        dMRVManager.adminSubmitVerification(pendingProjectId, 100, "ipfs://admin", false);
    }

    // --- Pausable ---

    function test_revert_whenPaused() public {
        vm.prank(admin);
        dMRVManager.pause();

        vm.expectRevert(bytes("EnforcedPause()"));
        vm.prank(projectDeveloper);
        dMRVManager.requestVerification(activeProjectId, keccak256("claim"), "uri", MOCK_MODULE_TYPE);
    }
}
