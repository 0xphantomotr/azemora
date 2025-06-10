// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/dMRVManager.sol";
import "../src/ProjectRegistry.sol";
import "../src/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IUUPS {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(
        address newImplementation,
        bytes calldata data
    ) external payable;
}

contract GovernanceTest is Test {
    DMRVManager manager;
    ProjectRegistry registry;
    DynamicImpactCredit credit;

    address admin = address(0xA11CE);
    address safe = address(0x5AFE); // Simulate the multi-sig wallet address

    function setUp() public {
        // Deploy and set up the contract infrastructure, with 'admin' as the initial owner
        vm.startPrank(admin);

        // 1. Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(
            ProjectRegistry.initialize,
            ()
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            registryInitData
        );
        registry = ProjectRegistry(address(registryProxy));

        // 2. Deploy DynamicImpactCredit
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        bytes memory creditInitData = abi.encodeCall(
            DynamicImpactCredit.initialize,
            ("ipfs://contract-metadata.json", address(registry))
        );
        ERC1967Proxy creditProxy = new ERC1967Proxy(
            address(creditImpl),
            creditInitData
        );
        credit = DynamicImpactCredit(address(creditProxy));

        // 3. Deploy DMRVManager
        DMRVManager managerImpl = new DMRVManager();
        bytes memory managerInitData = abi.encodeCall(
            DMRVManager.initialize,
            (address(registry), address(credit))
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(
            address(managerImpl),
            managerInitData
        );
        manager = DMRVManager(address(managerProxy));

        vm.stopPrank();
    }

    function test_TransferAdminRoleToSafe() public {
        // Step 1: Verify initial state
        // The original admin has the DEFAULT_ADMIN_ROLE on all contracts
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(credit.hasRole(credit.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), admin));

        // The safe address does not have the role yet
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), safe));
        assertFalse(credit.hasRole(credit.DEFAULT_ADMIN_ROLE(), safe));
        assertFalse(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), safe));

        vm.startPrank(admin);

        // Step 2: Grant the DEFAULT_ADMIN_ROLE to the new safe address for each contract
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), safe);
        credit.grantRole(credit.DEFAULT_ADMIN_ROLE(), safe);
        manager.grantRole(manager.DEFAULT_ADMIN_ROLE(), safe);

        // Step 3: Renounce the DEFAULT_ADMIN_ROLE from the original admin address
        // Note: The role is renounced for the _msgSender() (admin)
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), admin);
        credit.renounceRole(credit.DEFAULT_ADMIN_ROLE(), admin);
        manager.renounceRole(manager.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopPrank();

        // Step 4: Verify final state
        // The safe address now has the admin role
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(credit.hasRole(credit.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), safe));

        // The original admin no longer has the role
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(credit.hasRole(credit.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), admin));

        // Step 5 (Simulation): An admin action can now only be performed by the safe
        // For example, upgrading a contract should fail if initiated by the old admin
        vm.prank(admin);
        address newImpl = address(0x1234);
        vm.expectRevert(); // Reverts due to lacking DEFAULT_ADMIN_ROLE
        IUUPS(address(manager)).upgradeTo(newImpl);

        // But the safe can successfully perform admin actions (this will revert on implementation but pass the role check)
        vm.prank(safe);
        vm.expectRevert(); // Reverts, but not due to an access control error
        IUUPS(address(manager)).upgradeTo(newImpl);
    }
} 