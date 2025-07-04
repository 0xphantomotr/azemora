// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVerifierManager
 * @dev Interface for the VerifierManager, defining the functions that can be
 * called by the ArbitrationCouncil.
 */
interface IVerifierManager {
    /**
     * @notice Checks if an account is an active verifier.
     * @param account The address to check.
     * @return True if the account is an active verifier, false otherwise.
     */
    function isVerifier(address account) external view returns (bool);

    /**
     * @notice Slashes a verifier's stake for misconduct.
     * @param verifier The address of the verifier to be slashed.
     */
    function slash(address verifier) external;

    /**
     * @notice Returns a list of all registered verifiers.
     * @dev Used by the ArbitrationCouncil to select a peer jury.
     * NOTE: This is a placeholder for a more advanced selection mechanism.
     * @return A list of verifier addresses.
     */
    function getAllVerifiers() external view returns (address[] memory);

    function getVerifierStake(address account) external view returns (uint256);

    function getVerifierReputation(address account) external view returns (uint256);
}
