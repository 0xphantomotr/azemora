// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDePINOracle
 * @dev The standard interface for an oracle that reports data from a
 * Decentralized Physical Infrastructure Network (DePIN).
 * It provides a function to get the latest reading for a specific sensor.
 */
interface IDePINOracle {
    /**
     * @notice Fetches the latest reading for a specific sensor.
     * @param sensorId A unique identifier for the DePIN sensor.
     * @return value The numerical value of the sensor reading.
     * @return timestamp The timestamp when the reading was recorded by the oracle.
     */
    function getSensorReading(bytes32 sensorId) external view returns (uint256 value, uint256 timestamp);
}
