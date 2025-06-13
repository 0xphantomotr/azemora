// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/marketplace/Marketplace.sol";

/// @notice A mock V2 contract for testing the upgrade process.
/// @dev It adds a new state variable and a function to modify it, simulating a simple feature addition.
/// The UUPS upgrade pattern requires that the new implementation inherits from the old one.
contract MarketplaceV2 is Marketplace {
    /// @notice A new state variable to demonstrate a storage-extending upgrade.
    uint256 public version;

    /// @notice Sets the version number. Can be called after the upgrade.
    function setVersion(uint256 _newVersion) external {
        version = _newVersion;
    }
}
