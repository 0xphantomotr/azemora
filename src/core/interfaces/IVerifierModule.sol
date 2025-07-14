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
     * @notice Initiates a verification task within the module.
     * @param projectId The unique identifier of the project to verify.
     * @param claimId A unique identifier for the specific claim being verified.
     * @param evidenceURI A URI pointing to off-chain evidence related to the claim.
     * @return taskId A unique ID for the task created within the verifier module.
     */
    function startVerificationTask(bytes32 projectId, bytes32 claimId, string calldata evidenceURI)
        external
        returns (bytes32 taskId);

    /**
     * @notice Returns the name of the verifier module.
     * @return The module's name as a string.
     */
    function getModuleName() external view returns (string memory);
}
