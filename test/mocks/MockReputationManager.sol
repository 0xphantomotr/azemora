// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReputationManager} from "../../src/achievements/interfaces/IReputationManager.sol";

contract MockReputationManager is IReputationManager {
    mapping(address => uint256) public reputationScores;

    function getReputation(address user) external view override returns (uint256) {
        return reputationScores[user];
    }

    function addReputation(address, uint256) external override {
        // Not needed for these tests
    }

    function slashReputation(address user, uint256 amount) external override {
        if (reputationScores[user] >= amount) {
            reputationScores[user] -= amount;
        } else {
            reputationScores[user] = 0;
        }
    }

    // --- Test setup functions ---
    function setReputation(address user, uint256 amount) public {
        reputationScores[user] = amount;
    }
}
