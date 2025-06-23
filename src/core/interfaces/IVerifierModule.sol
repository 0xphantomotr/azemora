// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVerifierModule
 * @dev Interface for all dMRV verifier modules.
 * This standardizes how the dMRVManager interacts with different verification
 * mechanisms (e.g., reputation-weighted, ZK, DePIN).
 */
interface IVerifierModule {
    /**
     * @notice Initiates a verification task within the specific module.
     * @dev Called by the dMRVManager when a new verification is requested.
     * The module is responsible for its own internal logic for processing the task.
     * @param projectId The ID of the project being verified.
     * @param claimId A unique identifier for the specific claim being verified.
     * @param evidenceURI A URI pointing to off-chain evidence for the claim.
     * @return taskId A unique identifier for the task within the module.
     */
    function startVerificationTask(bytes32 projectId, bytes32 claimId, string calldata evidenceURI)
        external
        returns (bytes32 taskId);

    /**
     * @notice Returns the name of the module for identification purposes.
     * @return A string representing the module's name (e.g., "ReputationWeightedVerifier_v1").
     */
    function getModuleName() external pure returns (string memory);

    /**
     * @notice Returns the owner of the module.
     * @return The address of the owner.
     */
    function owner() external view returns (address);

    /**
     * @notice Delegate verification to another module.
     * @dev This function is used to delegate verification to another module.
     * @param claimId The ID of the claim being verified.
     * @param projectId The ID of the project being verified.
     * @param data Arbitrary data needed for the verification (e.g., IPFS CIDs).
     * @param originalSender The original user who initiated the request.
     */
    function delegateVerification(bytes32 claimId, bytes32 projectId, bytes calldata data, address originalSender)
        external;
}
