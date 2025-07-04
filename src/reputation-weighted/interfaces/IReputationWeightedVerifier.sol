// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReputationWeightedVerifier
 * @dev Interface for a verifier contract, defining the functions that can be
 * called by the ArbitrationCouncil.
 */
interface IReputationWeightedVerifier {
    /**
     * @notice Called by the ArbitrationCouncil to process the outcome of a dispute.
     * @param taskId The ID of the task being arbitrated.
     * @param finalAmount The final, quantitative outcome determined by the council's vote.
     */
    function processArbitrationResult(bytes32 taskId, uint256 finalAmount) external;

    /**
     * @notice Reverses a previously fulfilled verification.
     * @param claimId The unique ID of the claim to be reversed.
     */
    function reverseVerification(bytes32 claimId) external;
}
