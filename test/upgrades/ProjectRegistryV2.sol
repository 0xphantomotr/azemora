// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/core/ProjectRegistry.sol";

/**
 * @title ProjectRegistryV2
 * @dev A dummy V2 contract for testing the upgradeability of ProjectRegistry.
 * It adds a new state variable to ensure the storage gap is working as intended.
 */
contract ProjectRegistryV2 is ProjectRegistry {
    /// @notice A new state variable to demonstrate a storage-extending upgrade.
    string public registryName;

    /// @notice Sets the registry name. Can be called after the upgrade.
    function setRegistryName(string memory _newName) external {
        registryName = _newName;
    }
}
