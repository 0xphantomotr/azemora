// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {OracleManager} from "../../src/depin/OracleManager.sol";
import {DeviceRegistry} from "../../src/depin/DeviceRegistry.sol";
import {MockDePINOracle} from "../mocks/MockDePINOracle.sol";
import {IOracleManager} from "../../src/depin/interfaces/IOracleManager.sol";

// Import custom errors
import {OracleManager__QuorumNotMet, OracleManager__DeviationExceeded} from "../../src/depin/OracleManager.sol";

contract OracleManagerTest is Test {
    // --- Contracts ---
    OracleManager internal manager;
    DeviceRegistry internal registry;

    // --- Mocks & Users ---
    MockDePINOracle internal oracle1;
    MockDePINOracle internal oracle2;
    MockDePINOracle internal oracle3;
    address internal admin = makeAddr("admin");
    // This EOA owns the device NFT and authorizes oracles
    address internal deviceOwner = makeAddr("deviceOwner");
    // These are the EOAs that "operate" the oracles
    address internal oracle1Operator = makeAddr("oracle1Operator");
    address internal oracle2Operator = makeAddr("oracle2Operator");
    address internal oracle3Operator = makeAddr("oracle3Operator");

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
        // Arrange: 3 oracles, quorum of 2, 5% deviation
        _createSensorTypeAndAuthorizeOracles(2, 500, 3); // Authorize all 3 oracles
        vm.prank(oracle1Operator);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        vm.prank(oracle2Operator);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        vm.prank(oracle3Operator);
        oracle3.setMockReading(SENSOR_ID, 104, block.timestamp);

        // Act
        IOracleManager.AggregatedReading memory reading = manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);

        // Assert: Median of {100, 102, 104} is 102
        assertEq(reading.value, 102);
    }

    function test_Reverts_If_Quorum_Not_Met() public {
        // Arrange: 3 oracles, quorum of 3, but one oracle fails (value 0)
        _createSensorTypeAndAuthorizeOracles(3, 500, 3);
        vm.prank(oracle1Operator);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        vm.prank(oracle2Operator);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        vm.prank(oracle3Operator);
        oracle3.setMockReading(SENSOR_ID, 0, block.timestamp); // Failed oracle

        // Act & Assert
        vm.expectRevert(abi.encodeWithSelector(OracleManager__QuorumNotMet.selector, 2, 3));
        manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);
    }

    function test_Reverts_If_Deviation_Exceeded() public {
        // Arrange: 3 oracles, quorum of 3, 5% deviation, one value is too high
        _createSensorTypeAndAuthorizeOracles(3, 500, 3); // 5% deviation
        vm.prank(oracle1Operator);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        vm.prank(oracle2Operator);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp); // Median will be 102
        vm.prank(oracle3Operator);
        oracle3.setMockReading(SENSOR_ID, 120, block.timestamp); // 120 is > 5% deviation from 102

        // Max deviation amount = 102 * 500 / 10000 = 5
        vm.expectRevert(abi.encodeWithSelector(OracleManager__DeviationExceeded.selector, 120, 102, 5));
        manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);
    }

    function test_Unit_Ignores_Unauthorized_Oracles() public {
        // Arrange: Quorum of 2. Only 2 of 3 oracles are authorized.
        _createSensorTypeAndAuthorizeOracles(2, 500, 2); // Only authorize oracle1 and oracle2
        vm.prank(oracle1Operator);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        vm.prank(oracle2Operator);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        vm.prank(oracle3Operator);
        oracle3.setMockReading(SENSOR_ID, 999, block.timestamp); // This high value should be ignored as it's unauthorized

        // Act: The call should succeed because the 2 authorized oracles meet the quorum
        IOracleManager.AggregatedReading memory reading = manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);

        // Assert: Median of {100, 102} is 101
        assertEq(reading.value, 101);
    }

    function test_Reverts_If_Ignoring_Oracles_Causes_Quorum_Failure() public {
        // Arrange: Quorum of 3. Only 2 of 3 oracles are authorized.
        _createSensorTypeAndAuthorizeOracles(3, 500, 2); // Only authorize oracle1 and oracle2
        vm.prank(oracle1Operator);
        oracle1.setMockReading(SENSOR_ID, 100, block.timestamp);
        vm.prank(oracle2Operator);
        oracle2.setMockReading(SENSOR_ID, 102, block.timestamp);
        vm.prank(oracle3Operator);
        oracle3.setMockReading(SENSOR_ID, 999, block.timestamp);

        // Act & Assert: Only 2 responses are valid, but quorum is 3.
        vm.expectRevert(abi.encodeWithSelector(OracleManager__QuorumNotMet.selector, 2, 3));
        manager.getAggregatedReading(SENSOR_ID, SENSOR_TYPE);
    }

    // --- Helper Functions ---

    function _createSensorTypeAndAuthorizeOracles(uint8 quorum, uint32 deviationBps, uint256 numOraclesToAuthorize)
        internal
    {
        // 1. Create the Sensor Type in OracleManager
        vm.startPrank(admin);
        address[] memory oracles = new address[](3);
        oracles[0] = address(oracle1);
        oracles[1] = address(oracle2);
        oracles[2] = address(oracle3);
        manager.createSensorType(SENSOR_TYPE, quorum, deviationBps, oracles);
        vm.stopPrank();

        // 2. Register a SINGLE device in the registry, owned by `deviceOwner`
        vm.startPrank(admin);
        registry.grantRole(registry.MANUFACTURER_ROLE(), admin);
        uint256 tokenId = registry.registerDevice(SENSOR_ID, deviceOwner);
        vm.stopPrank();

        // 3. As the deviceOwner, authorize the oracle CONTRACTS to report for this device
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
 