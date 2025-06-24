// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/depin/interfaces/IDePINOracle.sol";

/**
 * @title MockDePINOracle
 * @dev A mock oracle for testing the DePINVerifier. It allows us to
 * programmatically set sensor readings to simulate various scenarios.
 */
contract MockDePINOracle is IDePINOracle {
    struct Reading {
        uint256 value;
        uint256 timestamp;
    }

    mapping(bytes32 => Reading) public mockReadings;

    /**
     * @notice Test-only function to set the mock return value for a sensor.
     * @param sensorId The ID of the sensor to mock.
     * @param value The value the sensor should report.
     * @param timestamp The timestamp the sensor should report.
     */
    function setMockReading(bytes32 sensorId, uint256 value, uint256 timestamp) external {
        mockReadings[sensorId] = Reading({value: value, timestamp: timestamp});
    }

    /**
     * @notice Implements the IDePINOracle interface to return the mocked data.
     */
    function getSensorReading(bytes32 sensorId) external view returns (uint256 value, uint256 timestamp) {
        Reading memory reading = mockReadings[sensorId];
        return (reading.value, reading.timestamp);
    }
}
