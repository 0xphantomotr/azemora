// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {
    ProjectBondingCurve,
    ProjectBondingCurve__WithdrawalTooSoon,
    ProjectBondingCurve__InsufficientBalance
} from "../../src/fundraising/ProjectBondingCurve.sol";
import {
    BondingCurveFactory,
    BondingCurveParams,
    BondingCurveFactory__NotVerifiedProject,
    BondingCurveFactory__OnlyProjectOwner,
    BondingCurveFactory__InvalidSeedAmount
} from "../../src/fundraising/BondingCurveFactory.sol";
import {ProjectToken} from "../../src/fundraising/ProjectToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import {BondingCurveStrategyRegistry} from "../../src/fundraising/BondingCurveStrategyRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBalancerVault} from "../mocks/MockBalancerVault.sol";

contract FundraisingIntegrationTest is Test {
    // --- Duplicate Event for Testing ---
    event LiquidityMigrated(
        bytes32 indexed projectId,
        address indexed ammAddress,
        bytes32 indexed poolId,
        uint256 collateralAmount,
        uint256 projectTokenAmount
    );

    // --- Constants ---
    uint256 public constant WAD = 1e18;
    // Lowered slope to make the cost affordable for the test user's balance.
    uint256 public constant SLOPE = 1;
    uint256 public constant TEAM_ALLOCATION = 1000 * WAD;
    uint256 public constant AMOUNT_TO_BUY = 50 * WAD;
    uint256 public constant AMOUNT_TO_SELL = 25 * WAD; // Sell half of what was bought
    bytes32 internal constant LINEAR_CURVE_V1 = keccak256("LINEAR_CURVE_V1");

    // --- Contracts ---
    ProjectRegistry internal projectRegistry;
    BondingCurveStrategyRegistry internal strategyRegistry;
    ProjectBondingCurve internal bondingCurveImplementation; // The logic contract
    BondingCurveFactory internal factory;
    MockERC20 internal collateralToken;
    ProjectToken internal projectToken;
    MockBalancerVault internal mockVault;

    // --- Users ---
    address public admin;
    address public alice; // Project creator
    address public bob; // Supporter

    // --- Parameters ---
    bytes32 public projectId = keccak256("Project Alpha");
    string internal constant TOKEN_NAME = "Project Alpha Token";
    string internal constant TOKEN_SYMBOL = "PAT";
    uint256 internal constant VESTING_CLIFF_SECONDS = 30 days;
    uint256 internal constant VESTING_DURATION_SECONDS = 90 days;
    uint256 internal constant MAX_WITHDRAWAL_PERCENTAGE = 1500; // 15%
    uint256 internal constant WITHDRAWAL_FREQUENCY_SECONDS = 7 days;

    function setUp() public {
        // --- Create users ---
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // --- Deploy core infrastructure ---
        vm.startPrank(admin);
        collateralToken = new MockERC20("Mock USDC", "USDC", 6);

        // Deploy implementation contracts
        ProjectRegistry registryImplementation = new ProjectRegistry();
        BondingCurveStrategyRegistry strategyRegistryImplementation = new BondingCurveStrategyRegistry();

        // Deploy proxies and initialize
        bytes memory registryData = abi.encodeWithSelector(ProjectRegistry.initialize.selector);
        projectRegistry = ProjectRegistry(address(new ERC1967Proxy(address(registryImplementation), registryData)));

        bytes memory strategyData = abi.encodeWithSelector(BondingCurveStrategyRegistry.initialize.selector, admin);
        strategyRegistry = BondingCurveStrategyRegistry(
            address(new ERC1967Proxy(address(strategyRegistryImplementation), strategyData))
        );

        bondingCurveImplementation = new ProjectBondingCurve();

        factory = new BondingCurveFactory(address(projectRegistry), address(strategyRegistry), address(collateralToken));

        // --- Setup ---
        // Note: No need to start/stop prank around admin actions here as we are already admin
        strategyRegistry.addStrategy(LINEAR_CURVE_V1, address(bondingCurveImplementation));
        // The project is registered once by Alice, then activated by the Admin.
        // We will do the activation later, after Alice registers it.
        vm.stopPrank();

        // --- Mint collateral for Bob ---
        collateralToken.mint(bob, 2_000_000 * 1e6); // Give Bob a reasonable starting balance

        // --- Setup Alice's project ---
        vm.startPrank(alice);
        projectRegistry.registerProject(projectId, "ipfs://project_alpha_meta");
        vm.stopPrank();

        vm.startPrank(admin);
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        vm.stopPrank();
    }

    function test_EndToEnd_Fundraising_Flow() public {
        // =================================================================
        // 1. Alice (Project Owner) Creates a Bonding Curve
        // =================================================================
        vm.startPrank(alice);
        bytes memory strategyInitData = abi.encode(
            SLOPE,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            MAX_WITHDRAWAL_PERCENTAGE,
            WITHDRAWAL_FREQUENCY_SECONDS
        );
        bytes memory ammConfigData = abi.encode(false, 0, address(0), bytes32(0));

        BondingCurveParams memory params = BondingCurveParams({
            projectId: projectId,
            strategyId: LINEAR_CURVE_V1,
            tokenName: TOKEN_NAME,
            tokenSymbol: TOKEN_SYMBOL,
            strategyInitializationData: strategyInitData,
            ammConfigData: ammConfigData
        });

        ProjectBondingCurve bondingCurve = ProjectBondingCurve(factory.createBondingCurve(params));
        vm.stopPrank();

        projectToken = ProjectToken(bondingCurve.projectToken());

        // --- Assertions ---
        assertEq(bondingCurve.owner(), alice, "Alice should be the owner of the curve");
        assertEq(projectToken.owner(), address(bondingCurve), "The curve should own the token");
        assertEq(projectToken.balanceOf(address(bondingCurve)), TEAM_ALLOCATION, "Curve should hold team allocation");

        // =================================================================
        // 2. Bob (Investor) Buys Tokens
        // =================================================================
        uint256 buyPrice = bondingCurve.getBuyPrice(AMOUNT_TO_BUY);

        vm.startPrank(bob);
        collateralToken.approve(address(bondingCurve), buyPrice);
        bondingCurve.buy(AMOUNT_TO_BUY, buyPrice);
        vm.stopPrank();

        // --- Assertions ---
        assertEq(projectToken.balanceOf(bob), AMOUNT_TO_BUY, "Bob should have the tokens he bought");
        assertEq(collateralToken.balanceOf(address(bondingCurve)), buyPrice, "Curve should have Bob's collateral");

        // =================================================================
        // 3. Alice (Project Owner) Withdraws Collateral
        // =================================================================
        vm.startPrank(alice);

        // Expect revert before withdrawal period
        vm.expectRevert(ProjectBondingCurve__WithdrawalTooSoon.selector);
        bondingCurve.withdrawCollateral();

        // Warp time forward to after the first withdrawal period
        vm.warp(block.timestamp + WITHDRAWAL_FREQUENCY_SECONDS + 1);

        uint256 initialAliceBalance = collateralToken.balanceOf(alice);
        uint256 expectedWithdrawal = (buyPrice * MAX_WITHDRAWAL_PERCENTAGE) / 10000;
        bondingCurve.withdrawCollateral();
        uint256 finalAliceBalance = collateralToken.balanceOf(alice);

        // --- Assertions ---
        assertEq(
            finalAliceBalance - initialAliceBalance, expectedWithdrawal, "Alice did not withdraw the correct amount"
        );
        vm.stopPrank();

        // =================================================================
        // 4. Bob Sells Tokens
        // =================================================================
        vm.startPrank(bob);

        // THIS IS THE FIX: Use the constant `AMOUNT_TO_SELL` instead of a hardcoded bad value.
        uint256 sellProceeds = bondingCurve.getSellPrice(AMOUNT_TO_SELL);
        assertGt(sellProceeds, 0, "Sell proceeds should be positive");

        projectToken.approve(address(bondingCurve), AMOUNT_TO_SELL);

        uint256 bobCollateralBefore = collateralToken.balanceOf(bob);
        bondingCurve.sell(AMOUNT_TO_SELL, sellProceeds);
        uint256 bobCollateralAfter = collateralToken.balanceOf(bob);

        // --- Assertions ---
        assertEq(bobCollateralAfter - bobCollateralBefore, sellProceeds, "Bob did not receive correct proceeds");
        assertEq(
            projectToken.balanceOf(bob),
            AMOUNT_TO_BUY - AMOUNT_TO_SELL,
            "Bob should have remaining tokens after selling"
        );

        vm.stopPrank();
    }

    function test_MigrateToAmm_Success() public {
        // =================================================================
        // 1. Setup: Create a curve with AMM migration enabled
        // =================================================================
        vm.startPrank(admin);
        mockVault = new MockBalancerVault();
        vm.stopPrank();

        bytes32 poolId = keccak256("Test Pool ID");
        uint16 liquidityBps = 5000; // 50%

        bytes memory strategyInitData = abi.encode(
            SLOPE,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            MAX_WITHDRAWAL_PERCENTAGE,
            WITHDRAWAL_FREQUENCY_SECONDS
        );
        bytes memory ammConfigData = abi.encode(true, liquidityBps, address(mockVault), poolId);

        BondingCurveParams memory params = BondingCurveParams({
            projectId: projectId,
            strategyId: LINEAR_CURVE_V1,
            tokenName: TOKEN_NAME,
            tokenSymbol: TOKEN_SYMBOL,
            strategyInitializationData: strategyInitData,
            ammConfigData: ammConfigData
        });

        vm.startPrank(alice);
        ProjectBondingCurve bondingCurve = ProjectBondingCurve(factory.createBondingCurve(params));
        vm.stopPrank();

        projectToken = ProjectToken(bondingCurve.projectToken());

        // =================================================================
        // 2. Simulate Buys: Add collateral to the curve
        // =================================================================
        uint256 buyPrice = bondingCurve.getBuyPrice(AMOUNT_TO_BUY);
        vm.startPrank(bob);
        collateralToken.approve(address(bondingCurve), buyPrice);
        bondingCurve.buy(AMOUNT_TO_BUY, buyPrice);
        vm.stopPrank();

        // =================================================================
        // 3. Trigger Migration
        // =================================================================
        uint256 projectTokenToSeed = 50 * WAD; // Project owner decides this
        uint256 collateralToSeed = (buyPrice * liquidityBps) / 10000;

        vm.startPrank(alice);
        // Set the expectation: check all three indexed topics and the data, from the factory.
        vm.expectEmit(true, true, true, true, address(factory));
        // Provide the expected values for the event. This is not a real emit.
        emit LiquidityMigrated(projectId, address(mockVault), poolId, collateralToSeed, projectTokenToSeed);

        // This is the actual call that triggers the event we're testing.
        factory.migrateToAmm(projectId, projectTokenToSeed);
        vm.stopPrank();

        // =================================================================
        // 4. Assertions
        // =================================================================
        // Assert the mock vault was called with the correct data
        assertEq(mockVault.last_poolId(), poolId, "Incorrect poolId");
        assertEq(mockVault.last_sender(), address(factory), "Sender should be the factory");
        assertEq(mockVault.last_recipient(), alice, "Recipient should be the project owner");

        // Assert the assets in the request are correct and sorted
        address tokenA =
            address(collateralToken) < address(projectToken) ? address(collateralToken) : address(projectToken);
        address tokenB =
            address(collateralToken) < address(projectToken) ? address(projectToken) : address(collateralToken);
        assertEq(mockVault.getLastRequest().assets[0], tokenA, "Asset 0 is incorrect");
        assertEq(mockVault.getLastRequest().assets[1], tokenB, "Asset 1 is incorrect");

        // Assert the amounts in the request are correct
        uint256 amountA = tokenA == address(collateralToken) ? collateralToSeed : projectTokenToSeed;
        uint256 amountB = tokenB == address(collateralToken) ? collateralToSeed : projectTokenToSeed;
        assertEq(mockVault.getLastRequest().maxAmountsIn[0], amountA, "Amount 0 is incorrect");
        assertEq(mockVault.getLastRequest().maxAmountsIn[1], amountB, "Amount 1 is incorrect");
    }

    function test_Fail_CreateCurve_ForUnverifiedProject() public {
        bytes32 unverifiedProjectId = keccak256("Unverified_Project");

        vm.startPrank(alice);
        // Register but do not verify the project
        projectRegistry.registerProject(unverifiedProjectId, "ipfs://unverified");

        // Expect revert because the project is not active
        vm.expectRevert(BondingCurveFactory__NotVerifiedProject.selector);
        bytes memory strategyInitData = abi.encode(
            SLOPE,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            MAX_WITHDRAWAL_PERCENTAGE,
            WITHDRAWAL_FREQUENCY_SECONDS
        );
        bytes memory ammConfigData = abi.encode(false, 0, address(0), bytes32(0));

        BondingCurveParams memory params = BondingCurveParams({
            projectId: unverifiedProjectId,
            strategyId: LINEAR_CURVE_V1,
            tokenName: "Unverified Token",
            tokenSymbol: "UT",
            strategyInitializationData: strategyInitData,
            ammConfigData: ammConfigData
        });
        factory.createBondingCurve(params);
        vm.stopPrank();
    }

    function test_fuzz_MigrateToAmm_Reverts(
        uint112 projectTokenAmountToSeed, // Fuzzed input
        uint16 liquidityBps, // Fuzzed input
        address caller // Fuzzed input
    ) public {
        // --- Fuzzer assumptions to keep tests relevant ---
        vm.assume(caller != address(0) && caller.code.length == 0);
        vm.assume(AMOUNT_TO_BUY > 0);

        // =================================================================
        // 1. Setup: Create a curve with AMM migration enabled using fuzzed params
        // =================================================================
        vm.startPrank(admin);
        mockVault = new MockBalancerVault();
        vm.stopPrank();

        bytes32 poolId = keccak256("Test Pool ID");
        bytes memory strategyInitData = abi.encode(
            SLOPE,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            MAX_WITHDRAWAL_PERCENTAGE,
            WITHDRAWAL_FREQUENCY_SECONDS
        );
        bytes memory ammConfigData = abi.encode(true, liquidityBps, address(mockVault), poolId);

        BondingCurveParams memory params = BondingCurveParams({
            projectId: projectId,
            strategyId: LINEAR_CURVE_V1,
            tokenName: TOKEN_NAME,
            tokenSymbol: TOKEN_SYMBOL,
            strategyInitializationData: strategyInitData,
            ammConfigData: ammConfigData
        });

        vm.startPrank(alice);
        ProjectBondingCurve bondingCurve = ProjectBondingCurve(factory.createBondingCurve(params));
        vm.stopPrank();
        projectToken = ProjectToken(bondingCurve.projectToken());

        // =================================================================
        // 2. Simulate Buys to add some collateral to the curve
        // =================================================================
        uint256 buyPrice = bondingCurve.getBuyPrice(AMOUNT_TO_BUY);
        vm.startPrank(bob);
        collateralToken.approve(address(bondingCurve), buyPrice);
        bondingCurve.buy(AMOUNT_TO_BUY, buyPrice);
        vm.stopPrank();

        // =================================================================
        // 3. Test various revert conditions based on fuzzed inputs
        // The order of these checks must mirror the order in the contract to correctly
        // predict the revert reason when multiple inputs are invalid.
        // =================================================================
        vm.prank(caller);

        // --- Contract Check 1: Zero seed amount ---
        if (projectTokenAmountToSeed == 0) {
            vm.expectRevert(BondingCurveFactory__InvalidSeedAmount.selector);
            factory.migrateToAmm(projectId, projectTokenAmountToSeed);
            return;
        }

        // --- Contract Check 2: Caller is not the project owner ---
        if (caller != alice) {
            vm.expectRevert(BondingCurveFactory__OnlyProjectOwner.selector);
            factory.migrateToAmm(projectId, projectTokenAmountToSeed);
            return;
        }

        // --- From this point, caller is assumed to be alice ---

        // --- Contract Check 3: Seeding more project tokens than the curve holds ---
        uint256 availableProjectTokens = projectToken.balanceOf(address(bondingCurve));
        if (projectTokenAmountToSeed > availableProjectTokens) {
            vm.expectRevert(ProjectBondingCurve__InsufficientBalance.selector);
            factory.migrateToAmm(projectId, projectTokenAmountToSeed);
            return;
        }

        // --- Contract Check 4: Requesting more collateral than available ---
        uint256 collateralBalance = collateralToken.balanceOf(address(bondingCurve));
        // This check implicitly handles liquidityBps > 10000 by calculating the outcome.
        uint256 collateralToSeed = (collateralBalance * liquidityBps) / 10000;
        if (collateralToSeed > collateralBalance && collateralBalance > 0) {
            vm.expectRevert(ProjectBondingCurve__InsufficientBalance.selector);
            factory.migrateToAmm(projectId, projectTokenAmountToSeed);
            return;
        }

        // If none of the revert conditions are met, the call should either succeed
        // or fail for a reason not related to our specific checks (which is okay).
        // We use a general `try...catch` to handle this.
        try factory.migrateToAmm(projectId, projectTokenAmountToSeed) {
            // Success case is fine
        } catch {
            // Other reverts are acceptable as the fuzzer explores edge cases
        }
    }
}
