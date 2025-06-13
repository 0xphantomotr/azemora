// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/governance/Treasury.sol";

/**
 * @title TreasuryV2
 * @dev A dummy V2 contract for testing the upgradeability of Treasury.
 */
contract TreasuryV2 is Treasury {
    /// @notice A new event to show V2 functionality.
    event V2Initialized();

    /// @notice An initializer for the V2 contract.
    function initializeV2() public {
        emit V2Initialized();
    }
}
