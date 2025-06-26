// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRewardCalculator
 * @dev The standard interface for a contract that calculates the reward amount
 * for a verified DePIN data reading. This modular approach allows for flexible
 * and upgradeable economic models.
 */
interface IRewardCalculator {
    /**
     * @notice Calculates the reward for a given verified value.
     * @param terms A bytes blob containing the specific parameters needed for this calculation.
     *        This allows each calculator to define its own required terms.
     * @param verifiedValue The aggregated and validated value from the OracleManager.
     * @return rewardAmount The final reward amount, to be used by the dMRVManager.
     */
    function calculateReward(bytes calldata terms, uint256 verifiedValue)
        external
        view
        returns (uint256 rewardAmount);
}
