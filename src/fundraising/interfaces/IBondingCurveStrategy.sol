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

    /**
     * @notice Releases a specified amount of collateral and project tokens from the bonding curve.
     * @dev This function is intended to be called by a trusted factory or manager contract
     * to seed a liquidity pool on a decentralized exchange.
     * It is the responsibility of the bonding curve implementation to ensure that only
     * an authorized address (e.g., its owner, which is the factory) can call this.
     * @param collateralAmount The amount of the collateral token to release.
     * @param projectTokenAmount The amount of the project token to release.
     */
    function releaseLiquidity(uint256 collateralAmount, uint256 projectTokenAmount) external;

    /**
     * @notice Returns the owner of the bonding curve.
     * @return The address of the owner.
     */
    function owner() external view returns (address);

    /**
     * @notice Returns the project token associated with the bonding curve.
     * @return The address of the project token.
     */
    function projectToken() external view returns (address);
}
