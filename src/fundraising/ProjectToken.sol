// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ProjectToken
 * @dev A standard, burnable ERC20 token for a single fundraising project.
 * The authority to mint new tokens is restricted to the owner of this contract,
 * which will be the project's dedicated ProjectBondingCurve contract.
 * The burn functionality allows users to sell tokens back to the curve.
 */
contract ProjectToken is ERC20, ERC20Burnable, Ownable {
    /**
     * @dev Sets the name, symbol, and initial owner of the token.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     * @param initialOwner The address that will be set as the contract owner.
     */
    constructor(string memory name, string memory symbol, address initialOwner)
        ERC20(name, symbol)
        Ownable(initialOwner)
    {}

    /**
     * @notice Mints new tokens and assigns them to a specified address.
     * @dev Can only be called by the contract owner (the ProjectBondingCurve).
     * @param to The address to receive the newly minted tokens.
     * @param amount The quantity of tokens to mint.
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
