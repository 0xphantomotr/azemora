// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IQuestVerifier.sol";

/**
 * @title TokenBalanceVerifier
 * @dev A quest verifier that checks if a user holds a minimum balance of a specific ERC20 token.
 * This contract is Ownable to allow an admin to update the minimum required balance.
 */
contract TokenBalanceVerifier is IQuestVerifier, Ownable {
    // --- Custom Errors ---
    error TokenBalanceVerifier__InvalidAddress();
    error TokenBalanceVerifier__InvalidAmount();

    // --- State ---
    IERC20 public immutable token;
    uint256 public minBalanceRequired;

    // --- Events ---
    event MinBalanceUpdated(uint256 newMinBalance);

    /**
     * @param tokenAddress The address of the ERC20 token to check.
     * @param minBalance The minimum balance required to pass verification.
     * @param initialOwner The initial owner of this contract.
     */
    constructor(address tokenAddress, uint256 minBalance, address initialOwner) Ownable(initialOwner) {
        if (tokenAddress == address(0)) revert TokenBalanceVerifier__InvalidAddress();
        if (minBalance == 0) revert TokenBalanceVerifier__InvalidAmount();
        token = IERC20(tokenAddress);
        minBalanceRequired = minBalance;
    }

    // --- IQuestVerifier Implementation ---

    /**
     * @inheritdoc IQuestVerifier
     */
    function verify(address user) external view override returns (bool) {
        return token.balanceOf(user) >= minBalanceRequired;
    }

    // --- Admin Functions ---

    /**
     * @notice Updates the minimum required token balance for the quest.
     * @dev Only callable by the owner.
     * @param newMinBalance The new minimum balance.
     */
    function setMinBalance(uint256 newMinBalance) external onlyOwner {
        if (newMinBalance == 0) revert TokenBalanceVerifier__InvalidAmount();
        minBalanceRequired = newMinBalance;
        emit MinBalanceUpdated(newMinBalance);
    }
}
