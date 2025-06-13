// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/core/DynamicImpactCredit.sol";

/**
 * @title DynamicImpactCreditV2
 * @dev A dummy V2 contract for testing the upgradeability of DynamicImpactCredit.
 */
contract DynamicImpactCreditV2 is DynamicImpactCredit {
    /// @notice A new state variable to demonstrate a storage-extending upgrade.
    bool public isV2;

    /// @notice An initializer for the V2 contract.
    function initializeV2() public {
        isV2 = true;
    }
}
