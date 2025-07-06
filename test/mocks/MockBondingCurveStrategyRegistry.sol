// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract MockBondingCurveStrategyRegistry is Ownable {
    enum StrategyStatus {
        None,
        Active,
        Deprecated
    }

    struct Strategy {
        address implementation;
        StrategyStatus status;
    }

    mapping(bytes32 => Strategy) public strategies;

    constructor() Ownable(msg.sender) {}

    function addStrategy(bytes32 strategyId, address implementation) external onlyOwner {
        require(implementation != address(0), "Zero address");
        require(strategies[strategyId].status == StrategyStatus.None, "Strategy already exists");

        strategies[strategyId] = Strategy({implementation: implementation, status: StrategyStatus.Active});
    }

    function getActiveStrategy(bytes32 strategyId) external view returns (address) {
        Strategy storage strategy = strategies[strategyId];
        require(strategy.status == StrategyStatus.Active, "Strategy not active");
        return strategy.implementation;
    }
}
