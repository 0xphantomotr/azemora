// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IRewardCalculator.sol";

/**
 * @title LinearRewardCalculator
 * @dev A simple reward calculator that implements a linear reward curve.
 * Rewards are calculated as: (verifiedValue - threshold) * multiplier
 * This contract is stateless and follows the IRewardCalculator interface.
 */
contract LinearRewardCalculator is IRewardCalculator {
    /**
     * @dev Defines the parameters required for the linear calculation.
     */
    struct LinearTerms {
        uint256 threshold;
        uint256 cap;
        uint256 multiplier;
    }

    /**
     * @inheritdoc IRewardCalculator
     * @dev Decodes LinearTerms and calculates the reward.
     * @param terms The ABI-encoded LinearTerms struct.
     * @param verifiedValue The value from the OracleManager.
     */
    function calculateReward(bytes calldata terms, uint256 verifiedValue)
        external
        pure
        override
        returns (uint256 rewardAmount)
    {
        LinearTerms memory decodedTerms = abi.decode(terms, (LinearTerms));

        if (verifiedValue < decodedTerms.threshold) {
            return 0;
        }

        uint256 effectiveValue = verifiedValue > decodedTerms.cap ? decodedTerms.cap : verifiedValue;

        // Note: This simple calculation assumes the multiplier and reward token have aligned decimal places.
        // A production-grade version could incorporate a decimals parameter in the terms.
        return (effectiveValue - decodedTerms.threshold) * decodedTerms.multiplier;
    }
}
