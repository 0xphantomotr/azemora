// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDMRVManager
 * @dev The interface for the dMRVManager contract. It defines the core
 * function that verifier modules must call to submit their results.
 */
interface IDMRVManager {
    /**
     * @notice Called by a verifier module to submit the result of a verification task.
     * @param projectId The ID of the project being verified.
     * @param claimId The unique ID for the specific claim.
     * @param resultData ABI-encoded data containing the verification outcome.
     * For example: `abi.encode(uint256 amountToMint, bool forceMetadataUpdate, ...)`
     */
    function fulfillVerification(bytes32 projectId, bytes32 claimId, bytes calldata resultData) external;
}
