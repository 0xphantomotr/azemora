// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDeviceRegistry
 * @dev The standard interface for a contract that manages the on-chain
 * identity of physical hardware devices using NFTs.
 */
interface IDeviceRegistry {
    /**
     * @notice Checks if a given address is the authorized data submitter for a specific device.
     * @dev The implementation should verify if the `submitter` is the owner of the NFT
     *      corresponding to the `deviceId`.
     * @param deviceId The unique identifier of the physical device.
     * @param submitter The address of the oracle or entity attempting to submit data.
     * @return A boolean indicating if the submitter is authorized.
     */
    function isAuthorizedSubmitter(bytes32 deviceId, address submitter) external view returns (bool);

    /**
     * @notice Returns the ERC-721 token ID associated with a given device ID.
     * @param deviceId The unique identifier of the physical device.
     * @return The token ID.
     */
    function getTokenId(bytes32 deviceId) external view returns (uint256);
}
