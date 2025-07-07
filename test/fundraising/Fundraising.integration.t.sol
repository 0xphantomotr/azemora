// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {
    ProjectBondingCurve, ProjectBondingCurve__WithdrawalTooSoon
} from "../../src/fundraising/ProjectBondingCurve.sol";
import {
    BondingCurveFactory,
    BondingCurveParams,
    BondingCurveFactory__NotVerifiedProject
} from "../../src/fundraising/BondingCurveFactory.sol";
import {ProjectToken} from "../../src/fundraising/ProjectToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import {BondingCurveStrategyRegistry} from "../../src/fundraising/BondingCurveStrategyRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract FundraisingIntegrationTest is Test {
    // --- Constants ---
    uint256 public constant WAD = 1e18;
    // Realistic slope to avoid overflow with WAD arithmetic
    uint256 public constant SLOPE = 1e9; // Price increases by 1 gwei per token
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
}
