// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/fundraising/BondingCurveFactory.sol";
import "../../src/fundraising/ExponentialCurve.sol";
import "../../src/fundraising/LogarithmicCurve.sol";
import "../../src/core/interfaces/IProjectRegistry.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockProjectRegistry.sol";
import "../mocks/MockBondingCurveStrategyRegistry.sol";

contract NewStrategiesIntegrationTest is Test {
    BondingCurveFactory internal factory;
    MockBondingCurveStrategyRegistry internal registry;
    MockProjectRegistry internal projectRegistry;
    MockERC20 internal collateralToken;

    ExponentialCurve internal exponentialCurveImplementation;
    LogarithmicCurve internal logarithmicCurveImplementation;

    address internal projectOwner = address(0x1);
    address internal user1 = address(0x2);

    bytes32 internal constant EXPONENTIAL_STRATEGY_ID = keccak256("EXPONENTIAL_V1");
    bytes32 internal constant LOGARITHMIC_STRATEGY_ID = keccak256("LOGARITHMIC_V1");

    // Strategy parameters
    // For Exponential curve, k must be small to prevent overflow. A k of 1 (1e-18 as a fixed point) is too high.
    // We'll use a k of 1 / 1e18, which is represented as a uint by the value 1.
    uint256 internal constant EXP_PRICE_COEFFICIENT = 1;
    uint256 internal constant LOG_PRICE_COEFFICIENT = 1e18; // k=1 is fine for logarithmic

    uint256 internal constant TEAM_ALLOCATION = 1000e18;
    uint256 internal constant VESTING_CLIFF_SECONDS = 30 days;
    uint256 internal constant VESTING_DURATION_SECONDS = 365 days;
    uint256 internal constant MAX_WITHDRAWAL_PERCENTAGE = 1500; // 15%
    uint256 internal constant WITHDRAWAL_FREQUENCY = 7 days;

    function setUp() public {
        // --- Deploy Core Infrastructure ---
        collateralToken = new MockERC20("Collateral", "COL", 18);
        projectRegistry = new MockProjectRegistry();
        registry = new MockBondingCurveStrategyRegistry();

        factory = new BondingCurveFactory(address(projectRegistry), address(registry), address(collateralToken));

        // --- Deploy and Register Strategies ---
        exponentialCurveImplementation = new ExponentialCurve();
        registry.addStrategy(EXPONENTIAL_STRATEGY_ID, address(exponentialCurveImplementation));

        logarithmicCurveImplementation = new LogarithmicCurve();
        registry.addStrategy(LOGARITHMIC_STRATEGY_ID, address(logarithmicCurveImplementation));

        // --- Fund User ---
        collateralToken.mint(user1, 1_000_000e18);
    }

    function test_DeployAndUseExponentialCurve() public {
        // 1. Setup Project in Registry
        bytes32 projectId = keccak256("Test Project Exponential");
        projectRegistry.addProject(projectId, projectOwner);
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);

        // 2. Prepare Initialization Data
        bytes memory strategyInitializationData = abi.encode(
            EXP_PRICE_COEFFICIENT,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            MAX_WITHDRAWAL_PERCENTAGE,
            WITHDRAWAL_FREQUENCY
        );

        // 3. Create the Bonding Curve via the Factory
        vm.prank(projectOwner);
        address curveAddress = factory.createBondingCurve(
            projectId, EXPONENTIAL_STRATEGY_ID, "Exponential Token", "EXPO", strategyInitializationData
        );
        assertTrue(curveAddress != address(0));

        // 4. Interact with the deployed curve
        ExponentialCurve deployedCurve = ExponentialCurve(payable(curveAddress));
        uint256 amountToBuy = 100e18;
        uint256 expectedCost = deployedCurve.getBuyPrice(amountToBuy);

        vm.startPrank(user1);
        collateralToken.approve(curveAddress, expectedCost);
        uint256 actualCost = deployedCurve.buy(amountToBuy, expectedCost);
        vm.stopPrank();

        assertEq(actualCost, expectedCost, "Buy cost should be correct on deployed exponential curve");
        assertEq(deployedCurve.projectToken().balanceOf(user1), amountToBuy, "User should receive project tokens");
    }

    function test_ExponentialCurve_VestingAndWithdrawal() public {
        // 1. Deploy the curve
        bytes32 projectId = keccak256("Test Vesting Exponential");
        projectRegistry.addProject(projectId, projectOwner);
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        bytes memory initData = abi.encode(
            EXP_PRICE_COEFFICIENT,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            MAX_WITHDRAWAL_PERCENTAGE,
            WITHDRAWAL_FREQUENCY
        );
        vm.prank(projectOwner);
        address curveAddress =
            factory.createBondingCurve(projectId, EXPONENTIAL_STRATEGY_ID, "Vesting Token", "VEST", initData);
        ExponentialCurve deployedCurve = ExponentialCurve(payable(curveAddress));
        ProjectToken projectToken = deployedCurve.projectToken();
        uint256 ownerInitialCollateral = collateralToken.balanceOf(projectOwner);

        // 2. Test Vesting: Cannot claim before cliff
        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(ExponentialCurve__VestingNotStarted.selector));
        deployedCurve.claimVestedTokens();

        // 3. Warp time past cliff & test vesting claim
        vm.warp(block.timestamp + VESTING_CLIFF_SECONDS + 1 days);
        vm.prank(projectOwner);
        uint256 vestedAmount = deployedCurve.claimVestedTokens();
        uint256 expectedVested = (TEAM_ALLOCATION * (VESTING_CLIFF_SECONDS + 1 days)) / VESTING_DURATION_SECONDS;
        assertEq(vestedAmount, expectedVested, "Incorrect vested amount after cliff");
        assertEq(projectToken.balanceOf(projectOwner), vestedAmount, "Owner should receive vested tokens");

        // 4. Simulate buys to add collateral
        vm.startPrank(user1);
        uint256 buyAmount = 50e18;
        uint256 cost = deployedCurve.getBuyPrice(buyAmount);
        collateralToken.approve(curveAddress, cost);
        deployedCurve.buy(buyAmount, cost);
        vm.stopPrank();

        // 5. First withdrawal succeeds because we warped time
        vm.prank(projectOwner);
        uint256 withdrawable = (cost * MAX_WITHDRAWAL_PERCENTAGE) / 10000;
        uint256 withdrawn = deployedCurve.withdrawCollateral();
        assertEq(withdrawn, withdrawable, "Incorrect withdrawal amount");
        assertEq(
            collateralToken.balanceOf(projectOwner),
            ownerInitialCollateral + withdrawn,
            "Owner should receive collateral"
        );

        // 6. Second withdrawal fails as it's too soon
        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(ExponentialCurve__WithdrawalTooSoon.selector));
        deployedCurve.withdrawCollateral();
    }

    function test_ExponentialCurve_RevertsOnOverflow() public {
        // 1. Deploy the curve with a very low supply to make it easier to hit overflow
        bytes32 projectId = keccak256("Overflow Test");
        projectRegistry.addProject(projectId, projectOwner);
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        bytes memory initData = abi.encode(1, 0, 0, 0, 10000, 0); // No team allocation, 100% withdrawal
        vm.prank(projectOwner);
        address curveAddress =
            factory.createBondingCurve(projectId, EXPONENTIAL_STRATEGY_ID, "Overflow", "OVER", initData);
        ExponentialCurve deployedCurve = ExponentialCurve(payable(curveAddress));

        // 2. Attempt a buy that will cause the s2^3 calculation to overflow uint256
        // The check inside the contract is for s2 > 2.2e25
        uint256 massiveBuy = 3e25;

        vm.startPrank(user1);
        collateralToken.approve(curveAddress, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ExponentialCurve__OverflowRisk.selector));
        deployedCurve.buy(massiveBuy, type(uint256).max);
    }
}
