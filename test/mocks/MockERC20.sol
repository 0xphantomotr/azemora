// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol) {
        //solhint-disable-next-line no-empty-blocks
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
