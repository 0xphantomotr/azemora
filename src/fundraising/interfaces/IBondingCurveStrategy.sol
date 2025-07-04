// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBondingCurveStrategy
 * @dev The interface that all bonding curve implementation contracts must adhere to.
 * This ensures that the BondingCurveFactory can safely initialize any approved strategy.
 */
interface IBondingCurveStrategy {
    /**
     * @notice Initializes a bonding curve strategy contract.
     * @param projectToken The address of the newly created, project-specific token.
     * @param collateralToken The address of the token used to buy the project token (e.g., USDC).
     * @param projectOwner The address that will own the bonding curve and receive withdrawn funds.
     * @param strategyInitializationData Abi-encoded data containing the parameters specific to this strategy
     * (e.g., slope, team allocation, etc.).
     */
    function initialize(
        address projectToken,
        address collateralToken,
        address projectOwner,
        bytes calldata strategyInitializationData
    ) external;
}
