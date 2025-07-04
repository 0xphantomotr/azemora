// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    BondingCurveStrategyRegistry,
    BondingCurveStrategyRegistry__ZeroAddress,
    BondingCurveStrategyRegistry__StrategyNotFound,
    BondingCurveStrategyRegistry__StrategyNotActive,
    BondingCurveStrategyRegistry__StrategyAlreadyExists,
    BondingCurveStrategyRegistry__StrategyInactive
} from "../../src/fundraising/BondingCurveStrategyRegistry.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract BondingCurveStrategyRegistryTest is Test {
    BondingCurveStrategyRegistry internal registry;
    address internal owner;
    address internal otherUser;
    address internal implementationV1;
    address internal implementationV2;

    bytes32 internal constant STRATEGY_ID = keccak256("LINEAR_V1");

    function setUp() public {
        owner = makeAddr("owner");
        otherUser = makeAddr("otherUser");
        implementationV1 = makeAddr("implementationV1");
        implementationV2 = makeAddr("implementationV2");

        // We must deploy the logic contract first, then the proxy, then initialize.
        // This correctly simulates the deployment of an upgradeable contract.
        BondingCurveStrategyRegistry logic = new BondingCurveStrategyRegistry();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(logic), abi.encodeCall(BondingCurveStrategyRegistry.initialize, (owner)));
        registry = BondingCurveStrategyRegistry(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                           OWNERSHIP & PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function test_permissions_onlyOwnerCanAddStrategy() public {
        vm.prank(otherUser);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, otherUser));
        registry.addStrategy(STRATEGY_ID, implementationV1);
    }

    function test_permissions_onlyOwnerCanUpdateStrategy() public {
        vm.prank(owner);
        registry.addStrategy(STRATEGY_ID, implementationV1);

        vm.prank(otherUser);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, otherUser));
        registry.updateStrategy(STRATEGY_ID, implementationV2);
    }

    function test_permissions_onlyOwnerCanDeprecateStrategy() public {
        vm.prank(owner);
        registry.addStrategy(STRATEGY_ID, implementationV1);

        vm.prank(otherUser);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, otherUser));
        registry.deprecateStrategy(STRATEGY_ID);
    }

    function test_permissions_onlyOwnerCanReactivateStrategy() public {
        vm.prank(owner);
        registry.addStrategy(STRATEGY_ID, implementationV1);
        vm.prank(owner);
        registry.deprecateStrategy(STRATEGY_ID);

        vm.prank(otherUser);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, otherUser));
        registry.reactivateStrategy(STRATEGY_ID);
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    function test_addStrategy_success() public {
        vm.prank(owner);
        registry.addStrategy(STRATEGY_ID, implementationV1);

        (address impl, BondingCurveStrategyRegistry.StrategyStatus status) = registry.strategies(STRATEGY_ID);
        assertEq(impl, implementationV1);
        assertEq(uint256(status), uint256(BondingCurveStrategyRegistry.StrategyStatus.Active));

        assertTrue(registry.isStrategyActive(STRATEGY_ID));
        assertEq(registry.getActiveStrategy(STRATEGY_ID), implementationV1);
    }

    function test_addStrategy_revertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BondingCurveStrategyRegistry__ZeroAddress.selector);
        registry.addStrategy(STRATEGY_ID, address(0));
    }

    function test_addStrategy_revertsIfAlreadyExists() public {
        vm.prank(owner);
        registry.addStrategy(STRATEGY_ID, implementationV1);

        vm.prank(owner);
        vm.expectRevert(BondingCurveStrategyRegistry__StrategyAlreadyExists.selector);
        registry.addStrategy(STRATEGY_ID, implementationV2);
    }

    function test_updateStrategy_success() public {
        vm.prank(owner);
        registry.addStrategy(STRATEGY_ID, implementationV1);
        vm.prank(owner);
        registry.updateStrategy(STRATEGY_ID, implementationV2);

        (address impl,) = registry.strategies(STRATEGY_ID);
        assertEq(impl, implementationV2);
    }

    function test_deprecateAndReactivate_success() public {
        vm.prank(owner);
        registry.addStrategy(STRATEGY_ID, implementationV1);
        assertTrue(registry.isStrategyActive(STRATEGY_ID));

        // Deprecate
        vm.prank(owner);
        registry.deprecateStrategy(STRATEGY_ID);
        assertFalse(registry.isStrategyActive(STRATEGY_ID));
        vm.expectRevert(BondingCurveStrategyRegistry__StrategyNotActive.selector);
        registry.getActiveStrategy(STRATEGY_ID);

        // Reactivate
        vm.prank(owner);
        registry.reactivateStrategy(STRATEGY_ID);
        assertTrue(registry.isStrategyActive(STRATEGY_ID));
        assertEq(registry.getActiveStrategy(STRATEGY_ID), implementationV1);
    }

    function test_deprecate_revertsIfNotActive() public {
        vm.prank(owner);
        vm.expectRevert(BondingCurveStrategyRegistry__StrategyNotActive.selector);
        registry.deprecateStrategy(STRATEGY_ID); // Not added yet
    }

    function test_reactivate_revertsIfNotDeprecated() public {
        vm.prank(owner);
        registry.addStrategy(STRATEGY_ID, implementationV1);

        vm.prank(owner);
        vm.expectRevert(BondingCurveStrategyRegistry__StrategyInactive.selector);
        registry.reactivateStrategy(STRATEGY_ID); // Is active, not deprecated
    }
}
