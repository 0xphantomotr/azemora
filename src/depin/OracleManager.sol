// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IOracleManager.sol";
import "./interfaces/IDePINOracle.sol";
import "./interfaces/IDeviceRegistry.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// --- Custom Errors ---
error OracleManager__ZeroAddress();
error OracleManager__InvalidQuorum();
error OracleManager__OracleNotTrusted();
error OracleManager__OracleAlreadyInSet();
error OracleManager__QuorumNotMet(uint256 responses, uint256 required);
error OracleManager__DeviationExceeded(uint256 value, uint256 median, uint256 maxDeviation);
error OracleManager__NoResponses();
error OracleManager__AlreadySet();
error OracleManager__NoValidReadings();

/**
 * @title OracleManager
 * @dev Manages configurations for sensor types and aggregates data from multiple trusted oracles
 * to provide a single, highly reliable data point. This contract is the core of the decentralized
 * data integrity layer for the DePIN verifier. It integrates a DeviceRegistry to ensure
 * data provenance from specific, authorized hardware.
 */
contract OracleManager is IOracleManager, AccessControlEnumerableUpgradeable, UUPSUpgradeable {
    // --- Structs ---
    struct SensorTypeConfig {
        uint8 minQuorum;
        uint32 deviationThresholdBps; // e.g., 200 bps = 2.00%
        address[] oracles;
    }

    // --- State ---
    mapping(bytes32 => SensorTypeConfig) public sensorTypeConfigs;
    mapping(address => bool) public isTrustedOracle;
    IDeviceRegistry public deviceRegistry;

    uint256[49] private __gap;

    // --- Events ---
    event SensorTypeCreated(bytes32 indexed sensorType, uint8 minQuorum, uint32 deviationBps);
    event OracleStatusUpdated(address indexed oracle, bool isTrusted);
    event DeviceRegistrySet(address indexed deviceRegistry);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        if (initialAdmin == address(0)) revert OracleManager__ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    // --- Admin Functions ---

    function setDeviceRegistry(address _deviceRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(deviceRegistry) != address(0)) revert OracleManager__AlreadySet();
        if (_deviceRegistry == address(0)) revert OracleManager__ZeroAddress();
        deviceRegistry = IDeviceRegistry(_deviceRegistry);
        emit DeviceRegistrySet(_deviceRegistry);
    }

    function setOracleStatus(address oracle, bool isTrusted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle == address(0)) revert OracleManager__ZeroAddress();
        isTrustedOracle[oracle] = isTrusted;
        emit OracleStatusUpdated(oracle, isTrusted);
    }

    function createSensorType(bytes32 sensorType, uint8 minQuorum, uint32 deviationBps, address[] calldata oracles)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (minQuorum == 0 || minQuorum > oracles.length) revert OracleManager__InvalidQuorum();

        for (uint256 i = 0; i < oracles.length; i++) {
            if (!isTrustedOracle[oracles[i]]) revert OracleManager__OracleNotTrusted();
        }

        sensorTypeConfigs[sensorType] =
            SensorTypeConfig({minQuorum: minQuorum, deviationThresholdBps: deviationBps, oracles: oracles});

        emit SensorTypeCreated(sensorType, minQuorum, deviationBps);
    }

    // --- Core Logic ---

    function getAggregatedReading(bytes32 sensorId, bytes32 sensorType)
        external
        view
        override
        returns (AggregatedReading memory)
    {
        SensorTypeConfig storage config = sensorTypeConfigs[sensorType];
        uint256 numOracles = config.oracles.length;

        uint256[] memory responses = new uint256[](numOracles);
        uint256 responseCount = 0;

        for (uint256 i = 0; i < numOracles; i++) {
            address oracleAddress = config.oracles[i];

            // --- THE FINAL VERIFICATION STEP ---
            // Before trusting the data, verify the oracle is authorized for the device.
            if (address(deviceRegistry) != address(0)) {
                if (!deviceRegistry.isOracleAuthorizedForDevice(sensorId, oracleAddress)) {
                    // This oracle is not authorized for this specific device. Skip.
                    continue;
                }
            }

            // slither-disable-next-line unused-return
            try IDePINOracle(oracleAddress).getSensorReading(sensorId) returns (uint256 value, uint256 timestamp) {
                // A production version would add more robust staleness checks here.
                // The 'timestamp' variable is intentionally unused in this version.
                if (value > 0) {
                    responses[responseCount] = value;
                    responseCount++;
                }
            } catch {
                // Oracle call failed, do nothing and continue
            }
        }

        if (responseCount < config.minQuorum) revert OracleManager__QuorumNotMet(responseCount, config.minQuorum);

        // Resize the array to only contain actual responses for sorting
        uint256[] memory validResponses = new uint256[](responseCount);
        for (uint256 i = 0; i < responseCount;) {
            validResponses[i] = responses[i];
            unchecked {
                ++i;
            }
        }

        _sort(validResponses);

        uint256 median = _findMedian(validResponses);

        _checkDeviations(validResponses, median, config.deviationThresholdBps);

        return AggregatedReading({value: median, timestamp: block.timestamp});
    }

    // --- Internal Helpers ---

    function _checkDeviations(uint256[] memory a, uint256 median, uint32 deviationBps) internal pure {
        uint256 maxDeviation = (median * deviationBps) / 10000;
        for (uint256 i = 0; i < a.length;) {
            uint256 diff = a[i] > median ? a[i] - median : median - a[i];
            if (diff > maxDeviation) {
                revert OracleManager__DeviationExceeded(a[i], median, maxDeviation);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _findMedian(uint256[] memory a) internal pure returns (uint256) {
        uint256 count = a.length;
        if (count == 0) revert OracleManager__NoResponses();

        if (count % 2 == 1) {
            return a[count / 2];
        } else {
            return (a[count / 2 - 1] + a[count / 2]) / 2;
        }
    }

    function _sort(uint256[] memory a) internal pure {
        uint256 n = a.length;
        for (uint256 i = 1; i < n;) {
            uint256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
            unchecked {
                ++i;
            }
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
