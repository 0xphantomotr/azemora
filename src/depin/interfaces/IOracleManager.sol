// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOracleManager
 * @dev The interface for the OracleManager contract, which is responsible for
 * aggregating data from multiple trusted DePIN oracles.
 */
interface IOracleManager {
    /**
     * @dev The data structure returned by a successful aggregation.
     */
    struct AggregatedReading {
        uint256 value;
        uint256 timestamp;
    }

    /**
     * @notice Retrieves and validates a sensor reading by aggregating data from multiple oracles.
     * @dev This function is the primary entry point for other contracts to get trusted data.
     * It should implement logic for quorum, deviation checks, and staleness.
     * @param sensorId The unique identifier of the physical sensor.
     * @param sensorType The type of sensor, used to look up the correct configuration.
     * @return A struct containing the aggregated value and the timestamp of the reading.
     */
    function getAggregatedReading(bytes32 sensorId, bytes32 sensorType)
        external
        view
        returns (AggregatedReading memory);
}
