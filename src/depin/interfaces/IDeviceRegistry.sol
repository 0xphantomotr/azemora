// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDeviceRegistry
 * @dev Interface for the on-chain device identity and authorization registry.
 */
interface IDeviceRegistry {
    /**
     * @notice Checks if a given address is an oracle authorized to submit data for a specific device.
     * @param deviceId The unique identifier of the physical device.
     * @param oracle The address of the oracle contract to check.
     * @return True if the address is the owner, false otherwise.
     */
    function isOracleAuthorizedForDevice(bytes32 deviceId, address oracle) external view returns (bool);

    /**
     * @notice Retrieves the NFT token ID for a given physical device ID.
     * @param deviceId The unique identifier of the physical device.
     * @return The uint256 token ID. Will revert if the device is not registered.
     */
    function getTokenId(bytes32 deviceId) external view returns (uint256);
}
