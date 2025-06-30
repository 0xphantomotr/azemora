// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDMRVManager
 * @dev Interface for the dMRVManager, defining the functions that can be
 * called by verifier modules.
 */
interface IDMRVManager {
    /**
     * @notice Callback function for registered verifier modules to deliver a final, trusted result.
     * @param projectId The ID of the project associated with the claim.
     * @param claimId The ID of the verification claim being fulfilled.
     * @param data The raw, encoded verification data from the module.
     */
    function fulfillVerification(bytes32 projectId, bytes32 claimId, bytes calldata data) external;

    /**
     * @notice Reverses a fulfillment after a successful challenge.
     * @dev This should trigger the burning of any erroneously minted credits.
     * @param projectId The ID of the project associated with the claim.
     * @param claimId The ID of the verification claim being reversed.
     */
    function reverseFulfillment(bytes32 projectId, bytes32 claimId) external;

    function setMethodologyRegistry(address _methodologyRegistry) external;
}
