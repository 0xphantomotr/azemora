// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// --- Custom Errors ---
error BondingCurveStrategyRegistry__ZeroAddress();
error BondingCurveStrategyRegistry__StrategyNotFound();
error BondingCurveStrategyRegistry__StrategyNotActive();
error BondingCurveStrategyRegistry__StrategyAlreadyExists();
error BondingCurveStrategyRegistry__StrategyInactive();

/**
 * @title BondingCurveStrategyRegistry
 * @author Azemora DAO
 * @dev A DAO-governed registry for various bonding curve implementation contracts.
 * This contract allows the platform to support multiple fundraising models without
 * requiring upgrades to the core factory contract.
 */
contract BondingCurveStrategyRegistry is Initializable, OwnableUpgradeable {
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

    event StrategyAdded(bytes32 indexed strategyId, address indexed implementation);
    event StrategyUpdated(bytes32 indexed strategyId, address indexed newImplementation);
    event StrategyStatusChanged(bytes32 indexed strategyId, StrategyStatus newStatus);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
    }

    /**
     * @notice Adds a new bonding curve strategy to the registry.
     * @dev Can only be called by the owner (DAO).
     * @param strategyId A unique identifier for the strategy (e.g., keccak256("LINEAR_V1")).
     * @param implementation The address of the deployed implementation contract.
     */
    function addStrategy(bytes32 strategyId, address implementation) external onlyOwner {
        if (implementation == address(0)) revert BondingCurveStrategyRegistry__ZeroAddress();
        if (strategies[strategyId].status != StrategyStatus.None) {
            revert BondingCurveStrategyRegistry__StrategyAlreadyExists();
        }

        strategies[strategyId] = Strategy({implementation: implementation, status: StrategyStatus.Active});
        emit StrategyAdded(strategyId, implementation);
        emit StrategyStatusChanged(strategyId, StrategyStatus.Active);
    }

    /**
     * @notice Updates the implementation address for an existing strategy.
     * @dev Can only be called by the owner (DAO). Useful for bug fixes or gas optimizations.
     * @param strategyId The ID of the strategy to update.
     * @param newImplementation The address of the new implementation contract.
     */
    function updateStrategy(bytes32 strategyId, address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert BondingCurveStrategyRegistry__ZeroAddress();
        if (strategies[strategyId].status == StrategyStatus.None) {
            revert BondingCurveStrategyRegistry__StrategyNotFound();
        }

        strategies[strategyId].implementation = newImplementation;
        emit StrategyUpdated(strategyId, newImplementation);
    }

    /**
     * @notice Deprecates a strategy, preventing its use in new fundraisers.
     * @dev Can only be called by the owner (DAO). Does not affect existing fundraisers.
     * @param strategyId The ID of the strategy to deprecate.
     */
    function deprecateStrategy(bytes32 strategyId) external onlyOwner {
        if (strategies[strategyId].status != StrategyStatus.Active) {
            revert BondingCurveStrategyRegistry__StrategyNotActive();
        }
        strategies[strategyId].status = StrategyStatus.Deprecated;
        emit StrategyStatusChanged(strategyId, StrategyStatus.Deprecated);
    }

    /**
     * @notice Reactivates a previously deprecated strategy.
     * @dev Can only be called by the owner (DAO).
     * @param strategyId The ID of the strategy to reactivate.
     */
    function reactivateStrategy(bytes32 strategyId) external onlyOwner {
        if (strategies[strategyId].status != StrategyStatus.Deprecated) {
            revert BondingCurveStrategyRegistry__StrategyInactive();
        }
        strategies[strategyId].status = StrategyStatus.Active;
        emit StrategyStatusChanged(strategyId, StrategyStatus.Active);
    }

    /**
     * @notice Retrieves the implementation address for an active strategy.
     * @param strategyId The ID of the strategy.
     * @return The address of the implementation contract.
     */
    function getActiveStrategy(bytes32 strategyId) external view returns (address) {
        Strategy storage strategy = strategies[strategyId];
        if (strategy.status != StrategyStatus.Active) {
            revert BondingCurveStrategyRegistry__StrategyNotActive();
        }
        return strategy.implementation;
    }

    /**
     * @notice Checks if a strategy is currently active.
     * @param strategyId The ID of the strategy.
     * @return True if the strategy is active, false otherwise.
     */
    function isStrategyActive(bytes32 strategyId) external view returns (bool) {
        return strategies[strategyId].status == StrategyStatus.Active;
    }
}
