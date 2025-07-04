// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IBondingCurveStrategy.sol";
import "./BondingCurveStrategyRegistry.sol";
import "../core/ProjectRegistry.sol";
import "./ProjectToken.sol";

// --- Custom Errors ---
error BondingCurveFactory__NotVerifiedProject();
error BondingCurveFactory__ZeroAddress();

/**
 * @title BondingCurveFactory
 * @author Azemora Team
 * @dev This is the single, authoritative entry point for creating new project fundraisers.
 * It acts as a security checkpoint by ensuring projects are verified in the ProjectRegistry,
 * and then deploys a standardized, gas-efficient bonding curve contract for them based on
 * a selected, DAO-approved strategy.
 */
contract BondingCurveFactory is Ownable {
    IProjectRegistry public immutable projectRegistry;
    BondingCurveStrategyRegistry public immutable strategyRegistry;
    address public immutable collateralToken;

    // Mapping from a project's ID to its deployed bonding curve contract address
    mapping(bytes32 => address) public getBondingCurve;

    event BondingCurveCreated(
        bytes32 indexed projectId,
        address indexed projectOwner,
        address bondingCurveAddress,
        address tokenAddress,
        bytes32 strategyId
    );

    constructor(address _registryAddress, address _strategyRegistryAddress, address _collateralToken)
        Ownable(msg.sender)
    {
        if (_registryAddress == address(0) || _strategyRegistryAddress == address(0) || _collateralToken == address(0))
        {
            revert BondingCurveFactory__ZeroAddress();
        }
        projectRegistry = IProjectRegistry(_registryAddress);
        strategyRegistry = BondingCurveStrategyRegistry(_strategyRegistryAddress);
        collateralToken = _collateralToken;
    }

    /**
     * @notice Creates and configures a new bonding curve fundraiser for a verified project.
     * @dev The caller (project creator) becomes the owner of the new bonding curve contract.
     * @param projectId The unique ID of the project in the ProjectRegistry.
     * @param strategyId The ID of the desired bonding curve strategy from the registry.
     * @param tokenName The name for the new project-specific token.
     * @param tokenSymbol The symbol for the new project-specific token.
     * @param strategyInitializationData The abi-encoded initialization data specific to the chosen strategy.
     * @return The address of the newly created ProjectBondingCurve contract.
     */
    function createBondingCurve(
        bytes32 projectId,
        bytes32 strategyId,
        string memory tokenName,
        string memory tokenSymbol,
        bytes calldata strategyInitializationData
    ) external returns (address) {
        // --- CRITICAL SECURITY CHECK ---
        if (!projectRegistry.isProjectActive(projectId)) {
            revert BondingCurveFactory__NotVerifiedProject();
        }

        // 1. Get the strategy implementation from the DAO-controlled registry.
        address implementation = strategyRegistry.getActiveStrategy(strategyId);

        // 2. Deploy the Project-Specific Token with the factory as a temporary owner.
        ProjectToken projectToken = new ProjectToken(tokenName, tokenSymbol, address(this));

        // 3. Deploy the Bonding Curve using a gas-efficient minimal proxy.
        address curveClone = Clones.clone(implementation);

        // 4. Transfer ownership of the token to its bonding curve contract BEFORE initializing.
        projectToken.transferOwnership(curveClone);

        // 5. Initialize the curve using the standardized interface.
        IBondingCurveStrategy(curveClone).initialize(
            address(projectToken),
            collateralToken,
            msg.sender, // The project creator becomes the owner of the curve
            strategyInitializationData
        );

        // 6. Record the new fundraiser and emit an event.
        getBondingCurve[projectId] = curveClone;
        emit BondingCurveCreated(projectId, msg.sender, curveClone, address(projectToken), strategyId);

        return curveClone;
    }
}
