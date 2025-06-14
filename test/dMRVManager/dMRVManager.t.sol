// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DMRVManagerTest is Test {
    DMRVManager dMRVManager;
    ProjectRegistry registry;
    DynamicImpactCredit credit;

    address admin = address(0xA11CE);
    address oracle = address(0x044C);
    address projectOwner = address(0x044E);

    bytes32 projectId = keccak256("Test Project");
    bytes32 requestId;

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
            abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://collection", address(registry)));
        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        // --- dMRVManager Setup ---
        DMRVManager dMRVManagerImpl = new DMRVManager();
        bytes memory dMRVManagerInitData = abi.encodeCall(DMRVManager.initialize, (address(registry), address(credit)));
        ERC1967Proxy dMRVManagerProxy = new ERC1967Proxy(address(dMRVManagerImpl), dMRVManagerInitData);
        dMRVManager = DMRVManager(address(dMRVManagerProxy));

        // --- Role Setup ---
        dMRVManager.grantRole(dMRVManager.ORACLE_ROLE(), oracle);
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));

        vm.stopPrank();

        // --- Initial State ---
        // Register and approve a project
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        // Make an initial verification request
        vm.prank(projectOwner);
        requestId = dMRVManager.requestVerification(projectId);
    }

    function test_RequestVerification_RevertsForNonActiveProject() public {
        // Register a new project, leave it in Pending state
        vm.prank(projectOwner);
        bytes32 pendingProjectId = keccak256("Pending Project");
        registry.registerProject(pendingProjectId, "ipfs://pending.json");

        vm.prank(projectOwner);
        vm.expectRevert("DMRVManager: Project not active");
        dMRVManager.requestVerification(pendingProjectId);
    }

    function test_FulfillVerification_RevertsForNonExistentRequest() public {
        bytes32 nonExistentRequestId = keccak256("non-existent");
        bytes memory data = abi.encode(100, false, bytes32(0), "ipfs://new.json");

        vm.prank(oracle);
        vm.expectRevert("DMRVManager: Request not found");
        dMRVManager.fulfillVerification(nonExistentRequestId, data);
    }

    function test_FulfillVerification_RevertsWhenAlreadyFulfilled() public {
        bytes memory data = abi.encode(100, false, bytes32(0), "ipfs://new.json");

        // Fulfill it once
        vm.prank(oracle);
        dMRVManager.fulfillVerification(requestId, data);

        // Try to fulfill it again
        vm.prank(oracle);
        vm.expectRevert("DMRVManager: Request already fulfilled");
        dMRVManager.fulfillVerification(requestId, data);
    }
}
