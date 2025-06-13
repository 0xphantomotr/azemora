// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "./DynamicImpactCreditV2.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DynamicImpactCreditUpgradeTest is Test {
    // Contracts
    DynamicImpactCredit credit; // The proxy
    DynamicImpactCreditV2 creditV2; // The V2 interface
    ProjectRegistry registry;

    // Users
    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address user = makeAddr("user");
    bytes32 projectId = keccak256("TestProject");
    uint256 tokenId;

    function setUp() public {
        tokenId = uint256(projectId);

        vm.startPrank(admin);

        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = ProjectRegistry(address(registryProxy));

        // Deploy V1 Credit Contract
        DynamicImpactCredit creditV1Impl = new DynamicImpactCredit();
        bytes memory creditInitData = abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://v1", address(registry)));
        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditV1Impl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        // Grant minter and verifier roles
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), minter);
        registry.grantRole(registry.VERIFIER_ROLE(), admin);

        // Register and activate the project
        // Note: The project registration must be done by its owner. We will prank as the project owner.
        // But for this test, let's simplify and have the admin also be the project owner.
        registry.registerProject(projectId, "ipfs://project");
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.stopPrank();

        // Mint some tokens to have state to check
        vm.prank(minter);
        credit.mintCredits(user, projectId, 100, "ipfs://batch1");
    }

    function test_upgradeCreditContract_preservesStateAndFunctionality() public {
        // --- 1. Pre-Upgrade Assertions ---
        assertEq(credit.balanceOf(user, tokenId), 100, "Pre-upgrade: user should have 100 tokens");
        string[] memory uriHistory = credit.getTokenURIHistory(tokenId);
        assertEq(uriHistory.length, 1, "Pre-upgrade: should have 1 URI in history");
        assertEq(uriHistory[0], "ipfs://batch1", "Pre-upgrade: URI should be correct");

        // --- 2. Deploy V2 and Upgrade ---
        vm.startPrank(admin);
        DynamicImpactCreditV2 creditV2Impl = new DynamicImpactCreditV2();
        // Use `upgradeToAndCall` to call the new V2 initializer
        bytes memory upgradeCallData = abi.encodeCall(DynamicImpactCreditV2.initializeV2, ());
        credit.upgradeToAndCall(address(creditV2Impl), upgradeCallData);
        vm.stopPrank();

        // --- 3. Post-Upgrade Assertions ---
        creditV2 = DynamicImpactCreditV2(address(credit));

        // Check that state is preserved
        assertEq(creditV2.balanceOf(user, tokenId), 100, "Post-upgrade: user balance should be preserved");
        string[] memory uriHistoryV2 = creditV2.getTokenURIHistory(tokenId);
        assertEq(uriHistoryV2.length, 1, "Post-upgrade: URI history length should be preserved");

        // Check that old functions still work
        vm.prank(minter);
        creditV2.mintCredits(user, projectId, 50, "ipfs://batch2");
        assertEq(creditV2.balanceOf(user, tokenId), 150, "Post-upgrade: minting should still work");
        uriHistoryV2 = creditV2.getTokenURIHistory(tokenId);
        assertEq(uriHistoryV2.length, 2, "Post-upgrade: URI history should be updated");
        assertEq(uriHistoryV2[1], "ipfs://batch2", "Post-upgrade: new URI should be correct");

        // Check that new V2 functionality works
        assertTrue(creditV2.isV2(), "V2 state variable 'isV2' should be true");
    }
}
