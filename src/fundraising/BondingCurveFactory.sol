// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ProjectBondingCurve.sol";
import "../core/ProjectRegistry.sol";

// --- Custom Errors ---
error BondingCurveFactory__NotVerifiedProject();
error BondingCurveFactory__ZeroAddress();

/**
 * @title BondingCurveFactory
 * @author Azemora Team
 * @dev This is the single, authoritative entry point for creating new project fundraisers.
 * It acts as a security checkpoint by ensuring projects are verified in the ProjectRegistry,
 * and then deploys a standardized, gas-efficient bonding curve contract for them.
 */
contract BondingCurveFactory is Ownable {
    IProjectRegistry public immutable projectRegistry;
    address public bondingCurveImplementation;
    address public immutable collateralToken;

    // Mapping from a project's ID to its deployed bonding curve contract address
    mapping(bytes32 => address) public getBondingCurve;

    event BondingCurveCreated(
        bytes32 indexed projectId, address indexed projectOwner, address bondingCurveAddress, address tokenAddress
    );

    constructor(address _registryAddress, address _implementationAddress, address _collateralToken)
        Ownable(msg.sender)
    {
        if (_registryAddress == address(0) || _implementationAddress == address(0) || _collateralToken == address(0)) {
            revert BondingCurveFactory__ZeroAddress();
        }
        projectRegistry = IProjectRegistry(_registryAddress);
        bondingCurveImplementation = _implementationAddress;
        collateralToken = _collateralToken;
    }

    /**
     * @notice Creates and configures a new bonding curve fundraiser for a verified project.
     * @dev The caller (project creator) becomes the owner of the new bonding curve contract.
     * @param projectId The unique ID of the project in the ProjectRegistry.
     * @param tokenName The name for the new project-specific token.
     * @param tokenSymbol The symbol for the new project-specific token.
     * @param slope The price slope for the linear bonding curve.
     * @param teamAllocation The amount of tokens reserved for the project team.
     * @param vestingCliffSeconds The duration of the vesting cliff in seconds.
     * @param vestingDurationSeconds The total duration of the vesting period in seconds.
     * @param maxWithdrawalPercentage The percentage of new collateral that can be withdrawn per period (e.g., 1500 for 15%).
     * @param withdrawalFrequencySeconds The frequency of withdrawals in seconds (e.g., 7 days).
     * @return The address of the newly created ProjectBondingCurve contract.
     */
    function createBondingCurve(
        bytes32 projectId,
        string memory tokenName,
        string memory tokenSymbol,
        uint256 slope,
        uint256 teamAllocation,
        uint256 vestingCliffSeconds,
        uint256 vestingDurationSeconds,
        uint256 maxWithdrawalPercentage,
        uint256 withdrawalFrequencySeconds
    ) external returns (address) {
        // --- CRITICAL SECURITY CHECK ---
        if (!projectRegistry.isProjectActive(projectId)) {
            revert BondingCurveFactory__NotVerifiedProject();
        }

        // 1. Deploy the Project-Specific Token with the factory as a temporary owner.
        ProjectToken projectToken = new ProjectToken(tokenName, tokenSymbol, address(this));

        // 2. Deploy the Bonding Curve using a gas-efficient minimal proxy.
        address curveClone = Clones.clone(bondingCurveImplementation);

        // 3. Transfer ownership of the token to its bonding curve contract BEFORE initializing.
        projectToken.transferOwnership(curveClone);

        // 4. Initialize the curve. Now it owns the token and can successfully mint the team allocation.
        ProjectBondingCurve(curveClone).initialize(
            address(projectToken),
            collateralToken,
            msg.sender, // The project creator becomes the owner of the curve
            slope,
            teamAllocation,
            vestingCliffSeconds,
            vestingDurationSeconds,
            maxWithdrawalPercentage,
            withdrawalFrequencySeconds
        );

        // 5. Record the new fundraiser and emit an event.
        getBondingCurve[projectId] = curveClone;
        emit BondingCurveCreated(projectId, msg.sender, curveClone, address(projectToken));

        return curveClone;
    }

    /**
     * @notice The owner can update the implementation contract for new deployments.
     * @param newImplementation The address of the new implementation contract.
     */
    function setImplementation(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert BondingCurveFactory__ZeroAddress();
        bondingCurveImplementation = newImplementation;
    }
}
