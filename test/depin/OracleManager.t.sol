// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {OracleManager} from "../../src/depin/OracleManager.sol";
import {DeviceRegistry} from "../../src/depin/DeviceRegistry.sol";
import {MockDePINOracle} from "../mocks/MockDePINOracle.sol";
import {IOracleManager} from "../../src/depin/interfaces/IOracleManager.sol";
import {IDeviceRegistry} from "../../src/depin/interfaces/IDeviceRegistry.sol";

// Import custom errors
import {
    OracleManager__QuorumNotMet,
    OracleManager__DeviationExceeded,
    OracleManager__OracleNotTrusted,
    OracleManager__NoResponses
} from "../../src/depin/OracleManager.sol";

// Minimal interface to call the upgrade function on a UUPS proxy
interface IUUPS {
    function upgradeTo(address newImplementation) external;
}

// A V2 contract for testing that inherits from the original and overrides the
// internal _lock function to prevent the implementation from being initialized.
contract OracleManagerV2 is OracleManager {
    event SensorTypeDeactivated(bytes32 indexed sensorType);

    function deactivateSensorType(bytes32 sensorType) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete sensorTypeConfigs[sensorType];
        emit SensorTypeDeactivated(sensorType);
    }
}

contract OracleManagerTest is Test {
    // --- Contracts ---
    OracleManager internal manager;
    DeviceRegistry internal registry;

    // --- Mocks & Users ---
    MockDePINOracle internal oracle1;
    MockDePINOracle internal oracle2;
    MockDePINOracle internal oracle3;
    address internal admin = makeAddr("admin");
    address internal deviceOwner = makeAddr("deviceOwner");
    address internal randomUser = makeAddr("randomUser");

    // --- State ---
    bytes32 internal constant SENSOR_ID = keccak256("test_sensor_123");
    bytes32 internal constant SENSOR_TYPE = keccak256("type_temperature");

    function setUp() public {
        // Deploy Registry
        DeviceRegistry registryImpl = new DeviceRegistry();
        bytes memory registryInitData =
            abi.encodeWithSelector(DeviceRegistry.initialize.selector, "Test Devices", "TD", admin);
        registry = DeviceRegistry(address(new ERC1967Proxy(address(registryImpl), registryInitData)));

        // Deploy OracleManager
        OracleManager managerImpl = new OracleManager();
        bytes memory managerInitData = abi.encodeWithSelector(OracleManager.initialize.selector, admin);
        manager = OracleManager(address(new ERC1967Proxy(address(managerImpl), managerInitData)));

        // Configure contracts
        vm.startPrank(admin);
        manager.setDeviceRegistry(address(registry));

        // Create and trust oracles
        oracle1 = new MockDePINOracle();
        oracle2 = new MockDePINOracle();
        oracle3 = new MockDePINOracle();
        manager.setOracleStatus(address(oracle1), true);
        manager.setOracleStatus(address(oracle2), true);
        manager.setOracleStatus(address(oracle3), true);
        vm.stopPrank();
    }

    // --- Core Logic Tests ---

    function test_Unit_GetAggregatedReading_Succeeds() public {
        _createSensorTypeAndAuthorizeOracles(2, 500, 3);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        oracle3.setMockReading(SENSOR_ID, 104, block.timestamp);
        IOracleManager.AggregatedReading memory reading = manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);
        assertEq(reading.value, 102);
    }

    function test_Reverts_If_Quorum_Not_Met() public {
        _createSensorTypeAndAuthorizeOracles(3, 500, 3);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        oracle3.setMockReading(SENSOR_ID, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleManager__QuorumNotMet.selector, 2, 3));
        manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);
    }

    function test_Reverts_If_Deviation_Exceeded() public {
        _createSensorTypeAndAuthorizeOracles(3, 500, 3);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        oracle3.setMockReading(SENSOR_ID, 120, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleManager__DeviationExceeded.selector, 120, 102, 5));
        manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);
    }

    function test_Unit_Ignores_Unauthorized_Oracles() public {
        _createSensorTypeAndAuthorizeOracles(2, 500, 2);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        oracle3.setMockReading(SENSOR_ID, 999, block.timestamp);
        IOracleManager.AggregatedReading memory reading = manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);
        assertEq(reading.value, 101);
    }

    function test_Reverts_If_Ignoring_Oracles_Causes_Quorum_Failure() public {
        _createSensorTypeAndAuthorizeOracles(3, 500, 2);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        oracle3.setMockReading(SENSOR_ID, 999, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleManager__QuorumNotMet.selector, 2, 3));
        manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);
    }

    // --- Access Control & Admin Tests ---

    function test_RevertIf_NonAdmin_SetsOracleStatus() public {
        vm.startPrank(randomUser);
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomUser, manager.DEFAULT_ADMIN_ROLE()
        );
        vm.expectRevert(expectedError);
        manager.setOracleStatus(address(oracle1), false);
        vm.stopPrank();
    }

    function test_RevertIf_NonAdmin_CreatesSensorType() public {
        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);
        vm.startPrank(randomUser);
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomUser, manager.DEFAULT_ADMIN_ROLE()
        );
        vm.expectRevert(expectedError);
        manager.createSensorType(SENSOR_TYPE, 1, 500, oracles);
        vm.stopPrank();
    }

    function test_RevertIf_CreateSensor_WithUntrustedOracle() public {
        vm.prank(admin);
        manager.setOracleStatus(address(oracle3), false);
        address[] memory oracles = new address[](3);
        oracles[0] = address(oracle1);
        oracles[1] = address(oracle2);
        oracles[2] = address(oracle3);
        vm.prank(admin);
        vm.expectRevert(OracleManager__OracleNotTrusted.selector);
        manager.createSensorType(SENSOR_TYPE, 3, 500, oracles);
    }

    // --- Edge Case & Upgrade Tests ---

    function test_RevertIf_GetReading_ForUnconfiguredSensorType() public {
        vm.expectRevert(OracleManager__NoResponses.selector);
        manager.getAggregatedReading(SENSOR_ID, "unconfigured_type");
    }

    // --- Helper Functions ---

    function _createSensorTypeAndAuthorizeOracles(uint8 quorum, uint32 deviationBps, uint256 numOraclesToAuthorize)
        internal
    {
        vm.startPrank(admin);
        address[] memory oracles = new address[](3);
        oracles[0] = address(oracle1);
        oracles[1] = address(oracle2);
        oracles[2] = address(oracle3);
        manager.createSensorType(SENSOR_TYPE, quorum, deviationBps, oracles);
        vm.stopPrank();

        vm.startPrank(admin);
        registry.grantRole(registry.MANUFACTURER_ROLE(), admin);
        uint256 tokenId = registry.registerDevice(SENSOR_ID, deviceOwner);
        vm.stopPrank();

        vm.startPrank(deviceOwner);
        if (numOraclesToAuthorize >= 1) {
            registry.addAuthorizedOracle(tokenId, address(oracle1));
        }
        if (numOraclesToAuthorize >= 2) {
            registry.addAuthorizedOracle(tokenId, address(oracle2));
        }
        if (numOraclesToAuthorize >= 3) {
            registry.addAuthorizedOracle(tokenId, address(oracle3));
        }
        vm.stopPrank();
    }
}
