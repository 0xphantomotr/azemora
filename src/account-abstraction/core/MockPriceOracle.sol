// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IPriceOracle.sol";

/**
 * @title MockPriceOracle
 * @dev A simple mock oracle for testing purposes.
 * It returns a hardcoded price to simulate a real price feed.
 */
contract MockPriceOracle is IPriceOracle {
    int256 private _price;

    constructor(int256 initialPrice) {
        _price = initialPrice;
    }

    function latestAnswer() external view override returns (int256) {
        return _price;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
    }
}
