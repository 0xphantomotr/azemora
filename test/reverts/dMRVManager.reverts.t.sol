// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/MethodologyRegistry.sol";
import {IVerificationData} from "../../src/core/interfaces/IVerificationData.sol";
import "../mocks/MockVerifierModule.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

contract DMRVManagerRevertsTest is Test {
    ProjectRegistry registry;
    DMRVManager dMRVManager;
    DynamicImpactCredit credit;
    MockVerifierModule mockModule;
    MethodologyRegistry methodologyRegistry;

    address admin = makeAddr("admin");
    address projectDeveloper = makeAddr("projectDeveloper");
    address verifier = makeAddr("verifier");
    address otherUser = makeAddr("otherUser");

    bytes32 activeProjectId = keccak256("Active Project");
    bytes32 pendingProjectId = keccak256("Pending Project");
    bytes32 public constant MOCK_MODULE_TYPE = keccak256("mock");

    function setUp() public {
        // Test contract is the deployer and initial admin
        // Deploy Registry
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(new ProjectRegistry()), abi.encodeCall(ProjectRegistry.initialize, ())))
        );

        // Deploy Credits
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(new DynamicImpactCredit()),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://"))
                )
            )
        );

        // Deploy MethodologyRegistry
        methodologyRegistry = MethodologyRegistry(
            address(
                new ERC1967Proxy(
                    address(new MethodologyRegistry()), abi.encodeCall(MethodologyRegistry.initialize, (address(this)))
                )
            )
        );

        // Deploy dMRV Manager
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

        mockModule = new MockVerifierModule();

        // Grant roles from the test contract (the admin)
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(dMRVManager));
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        dMRVManager.grantRole(dMRVManager.DEFAULT_ADMIN_ROLE(), admin);
        dMRVManager.grantRole(dMRVManager.PAUSER_ROLE(), admin);
        dMRVManager.grantRole(dMRVManager.MODULE_ADMIN_ROLE(), admin);
        methodologyRegistry.grantRole(methodologyRegistry.DEFAULT_ADMIN_ROLE(), admin);
        methodologyRegistry.grantRole(methodologyRegistry.METHODOLOGY_ADMIN_ROLE(), admin);

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
        // Setup: Register module via new flow
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        vm.prank(projectDeveloper);
        uint256 requestedAmount = 100e18;
        dMRVManager.requestVerification(pendingProjectId, keccak256("claim"), "uri", requestedAmount, MOCK_MODULE_TYPE);
    }

    // --- fulfillVerification ---

    function test_revert_fulfillVerification_notRegisteredModule() public {
        // Step 1: Register two different modules via new flow
        MockVerifierModule otherModule = new MockVerifierModule();
        bytes32 otherModuleType = keccak256("OTHER_MODULE");
        vm.startPrank(admin);

        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

        methodologyRegistry.addMethodology(otherModuleType, address(otherModule), "ipfs://other", bytes32(0));
        methodologyRegistry.approveMethodology(otherModuleType);
        dMRVManager.addVerifierModule(otherModuleType);

        vm.stopPrank();

        // Step 2: Create a valid request with the main module
        bytes32 claimId = keccak256("claim-to-fail");
        vm.prank(projectDeveloper);
        uint256 requestedAmount = 100e18;
        dMRVManager.requestVerification(activeProjectId, claimId, "uri", requestedAmount, MOCK_MODULE_TYPE);

        // Step 3: Attempt to fulfill from the wrong module
        IVerificationData.VerificationResult memory result = IVerificationData.VerificationResult({
            quantitativeOutcome: 100,
            wasArbitrated: false,
            arbitrationDisputeId: 0,
            credentialCID: "ipfs://data"
        });

        vm.prank(address(otherModule)); // Prank as the wrong module
        vm.expectRevert(DMRVManager__CallerNotRegisteredModule.selector);
        dMRVManager.fulfillVerification(activeProjectId, claimId, result);
    }

    function test_revert_fulfillVerification_claimNotFound() public {
        // Setup: Register module via new flow
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

        IVerificationData.VerificationResult memory result = IVerificationData.VerificationResult({
            quantitativeOutcome: 100,
            wasArbitrated: false,
            arbitrationDisputeId: 0,
            credentialCID: "ipfs://data"
        });
        vm.expectRevert(DMRVManager__ClaimNotFoundOrAlreadyFulfilled.selector);
        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(activeProjectId, keccak256("non-existent"), result);
    }

    function test_revert_fulfillVerification_alreadyFulfilled() public {
        // Step 1: Register module and create a valid request
        vm.prank(admin);
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

        vm.prank(projectDeveloper);
        bytes32 claimId = keccak256("my-claim");
        uint256 requestedAmount = 100e18;
        dMRVManager.requestVerification(activeProjectId, claimId, "uri", requestedAmount, MOCK_MODULE_TYPE);

        // Step 2: Fulfill it
        IVerificationData.VerificationResult memory result = IVerificationData.VerificationResult({
            quantitativeOutcome: 100,
            wasArbitrated: false,
            arbitrationDisputeId: 0,
            credentialCID: "ipfs://data"
        });
        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(activeProjectId, claimId, result);

        // Step 3: Try to fulfill it again
        vm.expectRevert(DMRVManager__ClaimNotFoundOrAlreadyFulfilled.selector);
        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(activeProjectId, claimId, result);
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
        uint256 requestedAmount = 100e18;
        dMRVManager.requestVerification(activeProjectId, keccak256("claim"), "uri", requestedAmount, MOCK_MODULE_TYPE);
    }
}
