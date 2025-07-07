// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IProjectBonding
 * @dev Defines the external functions for any bonding curve, enabling user interaction.
 * This is distinct from IBondingCurveStrategy, which is for factory-level initialization.
 */
interface IProjectBonding {
    // --- Events ---

    /**
     * @dev Emitted when a user buys project tokens from the bonding curve.
     * @param buyer The address of the user who purchased the tokens.
     * @param cost The amount of collateral (e.g., USDC) spent.
     * @param amount The amount of project tokens received by the buyer.
     */
    event Buy(address indexed buyer, uint256 cost, uint256 amount);

    /**
     * @dev Emitted when a user sells project tokens back to the bonding curve.
     * @param seller The address of the user who sold the tokens.
     * @param amount The amount of project tokens burned.
     * @param proceeds The amount of collateral (e.g., USDC) returned to the seller.
     */
    event Sell(address indexed seller, uint256 amount, uint256 proceeds);

    /**
     * @dev Emitted when the project owner withdraws funds from the bonding curve contract.
     * @param projectOwner The address of the project owner who initiated the withdrawal.
     * @param amount The amount of collateral withdrawn.
     */
    event Withdrawal(address indexed projectOwner, uint256 amount);

    // --- Functions ---

    /**
     * @notice Allows a user to buy project tokens by spending collateral.
     * @param amountToBuy The desired amount of project tokens.
     * @param maxCollateralToSpend The maximum amount of collateral the user is willing to spend to prevent slippage.
     * @return cost The actual amount of collateral spent.
     */
    function buy(uint256 amountToBuy, uint256 maxCollateralToSpend) external returns (uint256 cost);

    /**
     * @notice Allows a user to sell project tokens to receive collateral.
     * @param amountToSell The amount of project tokens to sell.
     * @param minCollateralToReceive The minimum amount of collateral the user is willing to receive to prevent slippage.
     * @return proceeds The actual amount of collateral received.
     */
    function sell(uint256 amountToSell, uint256 minCollateralToReceive) external returns (uint256 proceeds);

    /**
     * @notice Calculates the cost to buy a given amount of project tokens.
     * @param amountToBuy The amount of project tokens to query.
     * @return The cost in collateral tokens.
     */
    function getBuyPrice(uint256 amountToBuy) external view returns (uint256);

    /**
     * @notice Calculates the proceeds from selling a given amount of project tokens.
     * @param amountToSell The amount of project tokens to query.
     * @return The proceeds in collateral tokens.
     */
    function getSellPrice(uint256 amountToSell) external view returns (uint256);

    /**
     * @notice Allows the project owner to withdraw accumulated collateral based on defined rules.
     * @return The amount of collateral withdrawn.
     */
    function withdrawCollateral() external returns (uint256);
}
