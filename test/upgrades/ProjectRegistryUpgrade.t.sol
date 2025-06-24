// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "./ProjectRegistryV2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

contract ProjectRegistryUpgradeTest is Test {
    // Contracts
    ProjectRegistry registry; // The proxy
    ProjectRegistryV2 registryV2; // The V2 interface

    // Users
    address admin = makeAddr("admin");
    address projectOwner = makeAddr("projectOwner");
    bytes32 projectId = keccak256("TestProject");

    function setUp() public {
        vm.startPrank(admin);

        // Deploy V1 implementation and proxy
        ProjectRegistry registryV1Impl = new ProjectRegistry();
        bytes memory initData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(registryV1Impl), initData);
        registry = ProjectRegistry(address(proxy));

        // Set initial state on V1 that we will check after the upgrade
        vm.stopPrank();
        vm.startPrank(projectOwner);
        registry.registerProject(projectId, "ipfs://v1");
        vm.stopPrank();

        vm.startPrank(admin);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        vm.stopPrank();
    }

    function test_upgradeProjectRegistry_preservesStateAndFunctionality() public {
        // --- 1. Pre-Upgrade Assertions ---
        assertTrue(registry.isProjectActive(projectId), "Pre-upgrade: project should be active");
        IProjectRegistry.Project memory projectV1 = registry.getProject(projectId);
        assertEq(uint256(projectV1.status), 1, "Pre-upgrade: project status should be Active (1)");
        assertEq(projectV1.metaURI, "ipfs://v1", "Pre-upgrade: URI should be the V1 URI");

        // --- 2. Deploy V2 and Upgrade ---
        vm.startPrank(admin);
        ProjectRegistryV2 registryV2Impl = new ProjectRegistryV2();
        registry.upgradeToAndCall(address(registryV2Impl), "");
        vm.stopPrank();

        // --- 3. Post-Upgrade Assertions ---
        registryV2 = ProjectRegistryV2(address(registry));

        // Check that state is preserved
        assertTrue(registryV2.isProjectActive(projectId), "Post-upgrade: project should still be active");
        IProjectRegistry.Project memory projectV2 = registryV2.getProject(projectId);
        assertEq(projectV2.owner, projectOwner, "Post-upgrade: project owner should be preserved");

        // Check that old functions still work on the new implementation
        vm.startPrank(admin);
        registryV2.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Paused);
        assertEq(uint256(registryV2.getProject(projectId).status), 2, "Post-upgrade: setProjectStatus should work");
        vm.stopPrank();

        // Check that new V2 functionality works
        vm.startPrank(admin);
        registryV2.setRegistryName("Azemora Main Registry");
        assertEq(registryV2.registryName(), "Azemora Main Registry", "V2 function 'setRegistryName' should work");
    }
}
