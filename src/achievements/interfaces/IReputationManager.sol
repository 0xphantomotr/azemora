// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReputationManager
 * @dev The canonical interface for the ReputationManager contract.
 * It defines all externally callable functions for adding, slashing, and viewing reputation.
 */
interface IReputationManager {
    /**
     * @notice Adds reputation points to a user's score.
     * @param user The address of the user receiving the reputation.
     * @param amount The number of points to add.
     */
    function addReputation(address user, uint256 amount) external;

    /**
     * @notice Slashes (reduces) reputation points from a user's score.
     * @param user The address of the user whose reputation is being slashed.
     * @param amount The number of points to subtract.
     */
    function slashReputation(address user, uint256 amount) external;

    /**
     * @notice Retrieves the current reputation score for a given user.
     * @param user The address of the user.
     * @return The user's total reputation score.
     */
    function getReputation(address user) external view returns (uint256);
}
