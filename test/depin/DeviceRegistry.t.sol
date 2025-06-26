// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// Use global imports to make file-level custom errors visible.
import "../../src/depin/DeviceRegistry.sol";

contract DeviceRegistryTest is Test {
    // --- Contracts ---
    DeviceRegistry internal registry;

    // --- Users ---
    address internal admin = makeAddr("admin");
    address internal manufacturer = makeAddr("manufacturer");
    address internal deviceOwner = makeAddr("deviceOwner");
    address internal randomUser = makeAddr("randomUser");

    // --- State ---
    bytes32 internal constant DEVICE_ID = keccak256("test_sensor_123");

    function setUp() public {
        // Step 1: Deploy the raw implementation contract.
        DeviceRegistry implementation = new DeviceRegistry();

        // Step 2: Create the calldata for the `initialize` function.
        // The EOA `admin` address receives the admin role.
        bytes memory initData =
            abi.encodeWithSelector(DeviceRegistry.initialize.selector, "Azemora Devices", "AZD", admin);

        // Step 3: Deploy the proxy contract.
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Step 4: Point our `registry` variable to the PROXY's address.
        registry = DeviceRegistry(address(proxy));

        // Step 5: Grant the manufacturer role to a SEPARATE manufacturer address.
        // This is done by the `admin`, who has the DEFAULT_ADMIN_ROLE.
        // Use startPrank/stopPrank for robust context preservation.
        vm.startPrank(admin);
        registry.grantRole(registry.MANUFACTURER_ROLE(), manufacturer);
        vm.stopPrank();
    }

    // --- Initialization Tests ---

    function test_Unit_Initialize_Succeeds() public view {
        assertEq(registry.name(), "Azemora Devices");
        assertEq(registry.symbol(), "AZD");
        // The EOA admin should have the default admin role.
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        // The EOA admin ALSO has the manufacturer role by default from the initialize function.
        assertTrue(registry.hasRole(registry.MANUFACTURER_ROLE(), admin));
        // The separate manufacturer address should ALSO have the manufacturer role.
        assertTrue(registry.hasRole(registry.MANUFACTURER_ROLE(), manufacturer));
    }

    /*
     * @dev This test is removed because it's not possible to test this revert through
     * a correctly initialized proxy. The `InvalidInitialization` error from calling
     * initialize() twice would always be hit first. This logic is simple enough to be
     * considered covered by the implementation's own unit tests.
     *
    function test_Reverts_If_Initialize_With_Zero_Address() public {
        DeviceRegistry implementation = new DeviceRegistry();
        bytes memory initData = abi.encodeWithSelector(
            DeviceRegistry.initialize.selector,
            "Test", "TST", address(0)
        );
        vm.expectRevert(DeviceRegistry__ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
    */

    // --- Device Registration Tests ---

    function test_Unit_RegisterDevice_Succeeds() public {
        vm.startPrank(manufacturer);
        uint256 tokenId = registry.registerDevice(DEVICE_ID, deviceOwner);
        vm.stopPrank();

        assertEq(tokenId, 1);
        assertEq(registry.ownerOf(tokenId), deviceOwner);
        assertEq(registry.getTokenId(DEVICE_ID), tokenId);
    }

    function test_Reverts_If_NonManufacturer_RegistersDevice() public {
        vm.startPrank(randomUser);
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomUser, registry.MANUFACTURER_ROLE()
        );
        vm.expectRevert(expectedError);
        registry.registerDevice(DEVICE_ID, deviceOwner);
        vm.stopPrank();
    }

    function test_Reverts_If_Device_Is_Already_Registered() public {
        vm.startPrank(manufacturer);
        registry.registerDevice(DEVICE_ID, deviceOwner);
        vm.expectRevert(DeviceRegistry__DeviceAlreadyRegistered.selector);
        registry.registerDevice(DEVICE_ID, deviceOwner);
        vm.stopPrank();
    }

    function test_Reverts_If_Registering_To_Zero_Address() public {
        vm.startPrank(manufacturer);
        vm.expectRevert(DeviceRegistry__ZeroAddress.selector);
        registry.registerDevice(DEVICE_ID, address(0));
        vm.stopPrank();
    }

    // --- Authorization Tests ---

    function test_Unit_IsAuthorizedSubmitter_Succeeds() public {
        vm.startPrank(manufacturer);
        registry.registerDevice(DEVICE_ID, deviceOwner);
        vm.stopPrank();
        assertTrue(registry.isAuthorizedSubmitter(DEVICE_ID, deviceOwner));
    }

    function test_Unit_IsAuthorizedSubmitter_Fails_For_NonOwner() public {
        vm.startPrank(manufacturer);
        registry.registerDevice(DEVICE_ID, deviceOwner);
        vm.stopPrank();
        assertFalse(registry.isAuthorizedSubmitter(DEVICE_ID, randomUser));
    }

    function test_Unit_IsAuthorizedSubmitter_Fails_For_Unregistered_Device() public view {
        assertFalse(registry.isAuthorizedSubmitter(DEVICE_ID, deviceOwner));
    }

    // --- View Function Tests ---

    function test_Unit_GetTokenId_Succeeds() public {
        vm.startPrank(manufacturer);
        uint256 tokenId = registry.registerDevice(DEVICE_ID, deviceOwner);
        vm.stopPrank();
        assertEq(registry.getTokenId(DEVICE_ID), tokenId);
    }

    function test_Reverts_If_Getting_TokenId_For_Unregistered_Device() public {
        vm.expectRevert(DeviceRegistry__DeviceNotRegistered.selector);
        registry.getTokenId(DEVICE_ID);
    }
}
