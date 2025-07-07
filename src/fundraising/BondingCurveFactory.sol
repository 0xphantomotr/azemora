// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IBondingCurveStrategy.sol";
import "./BondingCurveStrategyRegistry.sol";
import "../core/ProjectRegistry.sol";
import "./ProjectToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IBalancerVault.sol";

// --- Structs ---
struct BondingCurveParams {
    bytes32 projectId;
    bytes32 strategyId;
    string tokenName;
    string tokenSymbol;
    bytes strategyInitializationData;
    bytes ammConfigData;
}

// --- Custom Errors ---
error BondingCurveFactory__NotVerifiedProject();
error BondingCurveFactory__ZeroAddress();
error BondingCurveFactory__AmmNotEnabled();
error BondingCurveFactory__OnlyProjectOwner();
error BondingCurveFactory__TransferFailed();
error BondingCurveFactory__InvalidSeedAmount();

/**
 * @title BondingCurveFactory
 * @author Genci Mehmeti
 * @dev This is the single, authoritative entry point for creating new project fundraisers.
 * It acts as a security checkpoint by ensuring projects are verified in the ProjectRegistry,
 * and then deploys a standardized, gas-efficient bonding curve contract for them based on
 * a selected, DAO-approved strategy. It also orchestrates the post-fundraise
 * migration of liquidity to a decentralized exchange.
 */
contract BondingCurveFactory is Ownable {
    using SafeERC20 for IERC20;
    using SafeERC20 for ProjectToken;

    IProjectRegistry public immutable projectRegistry;
    BondingCurveStrategyRegistry public immutable strategyRegistry;
    address public immutable collateralToken;

    // Mapping from a project's ID to its deployed bonding curve contract address
    mapping(bytes32 => address) public getBondingCurve;

    struct AmmConfig {
        bool enabled;
        uint16 liquidityPercentageBps; // Percentage of raised collateral to seed AMM with. 10000 = 100%
        address balancerVault;
        bytes32 poolId;
    }

    // Mapping from a project's ID to its AMM migration settings
    mapping(bytes32 => AmmConfig) public ammConfigs;

    event BondingCurveCreated(
        bytes32 indexed projectId,
        address indexed projectOwner,
        address bondingCurveAddress,
        address tokenAddress,
        bytes32 strategyId
    );

    event LiquidityMigrated(
        bytes32 indexed projectId,
        address indexed ammAddress,
        bytes32 indexed poolId,
        uint256 collateralAmount,
        uint256 projectTokenAmount
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
     * @param params A struct containing all the parameters for creating the bonding curve.
     * @return The address of the newly created ProjectBondingCurve contract.
     */
    function createBondingCurve(BondingCurveParams calldata params) external returns (address) {
        // --- CRITICAL SECURITY CHECK ---
        if (!projectRegistry.isProjectActive(params.projectId)) {
            revert BondingCurveFactory__NotVerifiedProject();
        }

        // 1. Get the strategy implementation from the DAO-controlled registry.
        address implementation = strategyRegistry.getActiveStrategy(params.strategyId);

        // 2. Delegate deployment to a helper function to manage stack depth.
        address curveClone = _deployCurveAndToken(
            implementation, params.tokenName, params.tokenSymbol, msg.sender, params.strategyInitializationData
        );

        // 3. Decode and store AMM configuration if enabled.
        (bool enableAmm, uint16 liquidityBps, address vault, bytes32 poolId) =
            abi.decode(params.ammConfigData, (bool, uint16, address, bytes32));
        if (enableAmm) {
            ammConfigs[params.projectId] =
                AmmConfig({enabled: true, liquidityPercentageBps: liquidityBps, balancerVault: vault, poolId: poolId});
        }

        // 4. Record the new fundraiser and emit an event.
        getBondingCurve[params.projectId] = curveClone;
        emit BondingCurveCreated(
            params.projectId,
            msg.sender,
            curveClone,
            IBondingCurveStrategy(curveClone).projectToken(),
            params.strategyId
        );

        return curveClone;
    }

    /**
     * @notice Migrates a percentage of the raised funds from a bonding curve to an AMM pool.
     * @dev This function can only be called once by the project owner after fundraising.
     * It pulls the specified assets from the bonding curve and seeds a new liquidity pool.
     * This function trusts the AMM router to handle the funds correctly.
     * @param projectId The unique ID of the project.
     * @param projectTokenAmountToSeed The amount of project tokens to seed the pool with.
     * This determines the initial price in the AMM.
     */
    function migrateToAmm(bytes32 projectId, uint256 projectTokenAmountToSeed) external {
        if (projectTokenAmountToSeed == 0) revert BondingCurveFactory__InvalidSeedAmount();

        AmmConfig memory config = ammConfigs[projectId];
        if (!config.enabled) revert BondingCurveFactory__AmmNotEnabled();

        address curveAddress = getBondingCurve[projectId];
        IBondingCurveStrategy curve = IBondingCurveStrategy(curveAddress);

        address projectOwner = curve.owner();
        if (projectOwner != msg.sender) revert BondingCurveFactory__OnlyProjectOwner();

        // 1. Calculate the collateral amount to transfer based on the config percentage
        uint256 collateralBalance = IERC20(collateralToken).balanceOf(curveAddress);
        uint256 collateralToSeed = (collateralBalance * config.liquidityPercentageBps) / 10000;

        // 2. Pull assets from the curve to this factory contract.
        curve.releaseLiquidity(collateralToSeed, projectTokenAmountToSeed);

        // 3. Add liquidity by calling the internal helper function
        _addLiquidityToBalancer(config, projectOwner, collateralToSeed, projectTokenAmountToSeed, curve.projectToken());

        // 4. Disable future migrations and emit event.
        delete ammConfigs[projectId];
        emit LiquidityMigrated(
            projectId, config.balancerVault, config.poolId, collateralToSeed, projectTokenAmountToSeed
        );
    }

    /**
     * @dev Internal helper to deploy the token and bonding curve.
     * Encapsulated to manage stack depth.
     */
    function _deployCurveAndToken(
        address implementation,
        string memory tokenName,
        string memory tokenSymbol,
        address projectOwner,
        bytes calldata strategyInitializationData
    ) internal returns (address) {
        // 1. Deploy the Project-Specific Token with the factory as a temporary owner.
        ProjectToken projectToken = new ProjectToken(tokenName, tokenSymbol, address(this));

        // 2. Deploy the Bonding Curve using a gas-efficient minimal proxy.
        address curveClone = Clones.clone(implementation);

        // 3. Transfer ownership of the token to its bonding curve contract BEFORE initializing.
        projectToken.transferOwnership(curveClone);

        // 4. Initialize the curve using the standardized interface.
        IBondingCurveStrategy(curveClone).initialize(
            address(projectToken), collateralToken, projectOwner, strategyInitializationData
        );

        return curveClone;
    }

    /**
     * @dev Internal helper to add liquidity to a Balancer pool.
     * Encapsulated to manage stack depth.
     */
    function _addLiquidityToBalancer(
        AmmConfig memory config,
        address projectOwner,
        uint256 collateralToSeed,
        uint256 projectTokenAmountToSeed,
        address projectTokenAddress
    ) internal {
        // Balancer requires assets to be sorted by address.
        address tokenA = collateralToken < projectTokenAddress ? collateralToken : projectTokenAddress;
        address tokenB = collateralToken < projectTokenAddress ? projectTokenAddress : collateralToken;

        uint256 amountA = tokenA == collateralToken ? collateralToSeed : projectTokenAmountToSeed;
        uint256 amountB = tokenB == collateralToken ? collateralToSeed : projectTokenAmountToSeed;

        // Approve the Balancer Vault to spend the tokens held by this factory.
        IERC20(tokenA).approve(config.balancerVault, amountA);
        IERC20(tokenB).approve(config.balancerVault, amountB);

        // Construct the JoinPoolRequest.
        address[] memory assets = new address[](2);
        assets[0] = tokenA;
        assets[1] = tokenB;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = amountA;
        maxAmountsIn[1] = amountB;

        // For initial liquidity, the userData is abi.encode(0, amountsIn). `0` is the `INIT` action.
        bytes memory userData = abi.encode(uint256(0), maxAmountsIn);

        IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest({
            assets: assets,
            maxAmountsIn: maxAmountsIn,
            userData: userData,
            fromInternalBalance: false
        });

        // Join the Balancer pool.
        IBalancerVault(config.balancerVault).joinPool(
            config.poolId,
            address(this), // The factory sends the tokens
            projectOwner, // The project owner receives the BPT (LP tokens)
            request
        );
    }
}
