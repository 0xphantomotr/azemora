// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IProjectBonding
 * @dev The universal interface for all project-specific bonding curve contracts.
 * This ensures predictability and allows third-party tools to reliably interact
 * with any project fundraiser on the Azemora platform.
 */
interface IProjectBonding {
    // --- Events ---

    /**
     * @dev Emitted when a user buys project tokens from the bonding curve.
     * @param buyer The address of the user who purchased the tokens.
     * @param collateralAmount The amount of collateral (e.g., USDC) spent.
     * @param tokensMinted The amount of project tokens received by the buyer.
     */
    event Buy(address indexed buyer, uint256 collateralAmount, uint256 tokensMinted);

    /**
     * @dev Emitted when a user sells project tokens back to the bonding curve.
     * @param seller The address of the user who sold the tokens.
     * @param tokensBurned The amount of project tokens burned.
     * @param collateralReturned The amount of collateral (e.g., USDC) returned to the seller.
     */
    event Sell(address indexed seller, uint256 tokensBurned, uint256 collateralReturned);

    /**
     * @dev Emitted when the project owner withdraws funds from the bonding curve contract.
     * @param projectOwner The address of the project owner who initiated the withdrawal.
     * @param amountWithdrawn The amount of collateral withdrawn.
     */
    event Withdrawal(address indexed projectOwner, uint256 amountWithdrawn);

    // --- Functions ---

    /**
     * @notice Allows a user to purchase project tokens by sending collateral.
     * @param amountToBuy The amount of project tokens the user wishes to receive.
     * @param maxCollateralToSpend The maximum amount of collateral the user is willing to spend to prevent slippage.
     * @return The actual amount of collateral spent.
     */
    function buy(uint256 amountToBuy, uint256 maxCollateralToSpend) external returns (uint256);

    /**
     * @notice Allows a user to sell their project tokens back to the curve for collateral.
     * @param amountToSell The amount of project tokens the user wishes to sell.
     * @param minCollateralToReceive The minimum amount of collateral the user is willing to receive to prevent slippage.
     * @return The actual amount of collateral received.
     */
    function sell(uint256 amountToSell, uint256 minCollateralToReceive) external returns (uint256);

    /**
     * @notice Allows the project owner to withdraw raised funds according to protocol safeguards.
     * @return The amount of collateral successfully withdrawn.
     */
    function withdrawCollateral() external returns (uint256);

    /**
     * @notice Calculates the amount of collateral required to buy a certain amount of project tokens.
     * @param amountToBuy The amount of project tokens to be purchased.
     * @return The required amount of collateral.
     */
    function getBuyPrice(uint256 amountToBuy) external view returns (uint256);

    /**
     * @notice Calculates the amount of collateral a user will receive for selling a certain amount of project tokens.
     * @param amountToSell The amount of project tokens to be sold.
     * @return The amount of collateral the user will receive.
     */
    function getSellPrice(uint256 amountToSell) external view returns (uint256);
}
