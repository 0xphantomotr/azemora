// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockCollateral
 * @dev A simple ERC20 token for testing purposes. Includes a public mint function
 * to allow test setups to easily distribute tokens to test accounts.
 */
contract MockCollateral is ERC20 {
    constructor() ERC20("Mock Collateral", "MOCK") {}

    /**
     * @notice Creates `amount` tokens for `to`, increasing the total supply.
     * @dev Public mint for testing convenience.
     */
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
