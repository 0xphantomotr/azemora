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
     * @param challenger The address initiating the challenge.
     * @param defendant The address of the entity whose decision is being challenged.
     */
    function createDispute(bytes32 claimId, address challenger, address defendant) external returns (bool);
}
