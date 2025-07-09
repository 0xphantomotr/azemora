// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice A minimal mock of the StakingManager for testing purposes.
contract MockStakingManager {
    event Slashed(uint256 amount, address compensationTarget);

    /// @notice Mocks the slash function to emit an event and succeed.
    function slash(uint256 amount, address compensationTarget) external {
        emit Slashed(amount, compensationTarget);
    }
}
