// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReputationWeightedVerifier
 * @dev Interface for a verifier contract, defining the functions that can be
 * called by the ArbitrationCouncil.
 */
interface IReputationWeightedVerifier {
    /**
     * @notice Reverses a prior verification outcome after a successful challenge.
     * @param claimId The unique ID of the claim to be reversed.
     */
    function reverseVerification(bytes32 claimId) external;

    /**
     * @notice Processes the final outcome of an arbitration.
     * @dev Called by the ArbitrationCouncil once a dispute is resolved. This contract
     * is then responsible for enacting the consequences (slashing, etc.).
     * @param taskId The ID of the task that was disputed.
     * @param overturned True if the original decision was overturned, false if it was upheld.
     */
    function processArbitrationResult(bytes32 taskId, bool overturned) external;
}
