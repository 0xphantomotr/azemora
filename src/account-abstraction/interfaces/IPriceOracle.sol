// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPriceOracle
 * @dev A simple interface for a contract that provides a price feed.
 * In a real-world scenario, this would be implemented by a Chainlink oracle.
 */
interface IPriceOracle {
    /**
     * @notice Returns the latest price.
     * @dev For our use case, this would represent the exchange rate,
     * e.g., how many AzemoraToken wei are equivalent to 1 ETH wei.
     * @return The latest price or exchange rate.
     */
    function latestAnswer() external view returns (int256);
}
