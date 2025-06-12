// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title AzemoraTimelockController
 * @author Genci Mehmeti
 * @dev A simple, upgradeable wrapper for OpenZeppelin's TimelockController.
 * This contract will be the owner of other contracts in the system, and will
 * execute transactions proposed and passed by the AzemoraGovernor.
 */
contract AzemoraTimelockController is Initializable, TimelockControllerUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        public
        override
        initializer
    {
        __TimelockController_init(minDelay, proposers, executors, admin);
    }
}
