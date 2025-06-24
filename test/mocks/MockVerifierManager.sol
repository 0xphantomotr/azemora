// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VerifierManager} from "../../src/reputation-weighted/VerifierManager.sol";

/**
 * @title MockVerifierManager
 * @dev This contract inherits from the real VerifierManager but overrides the
 *      constructor to be empty. This removes the `_disableInitializers()` call,
 *      making the contract's initializer function callable in a test environment.
 *      This is a standard pattern for testing upgradeable contracts without proxies.
 */
contract MockVerifierManager is VerifierManager {
    constructor() {}
}
