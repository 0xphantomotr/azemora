// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAchievementSBT
 * @dev The interface for the AchievementsSBT contract, defining the minting function.
 */
interface IAchievementSBT {
    /**
     * @notice Mints a new achievement badge (SBT) for a user.
     * @param to The address of the user receiving the achievement.
     * @param achievementId The ID of the achievement to mint.
     * @param amount The quantity to mint (typically 1 for SBTs).
     */
    function mintAchievement(address to, uint256 achievementId, uint256 amount) external;
}
