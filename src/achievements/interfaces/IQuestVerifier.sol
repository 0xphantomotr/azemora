// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IQuestVerifier
 * @dev The standard interface for all on-chain quest verification contracts.
 * The QuestManager calls the `verify` function on these contracts to determine
 * if a user has completed the requirements for a quest.
 */
interface IQuestVerifier {
    /**
     * @notice Checks if a user has met the quest's conditions.
     * @param user The address of the user attempting to complete the quest.
     * @return A boolean indicating whether the conditions are met (true) or not (false).
     */
    function verify(address user) external view returns (bool);
}
