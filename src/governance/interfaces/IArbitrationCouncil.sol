// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IArbitrationCouncil
 * @dev Interface for the ArbitrationCouncil, defining the functions that can be
 * called by other contracts like the ReputationWeightedVerifier.
 */
interface IArbitrationCouncil {
    /**
     * @notice Creates a new dispute.
     * @param claimId The unique ID of the verification claim being challenged.
     * @param defendant The address of the entity whose decision is being challenged.
     * @param signature A signature from the challenger proving their intent to challenge.
     */
    function createDispute(bytes32 claimId, address defendant, bytes calldata signature) external returns (bool);
}
