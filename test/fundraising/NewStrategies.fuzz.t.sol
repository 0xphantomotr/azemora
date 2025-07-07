// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/fundraising/BondingCurveFactory.sol";
import "../../src/fundraising/ExponentialCurve.sol";
import "../../src/fundraising/LogarithmicCurve.sol";
import "../../src/core/interfaces/IProjectRegistry.sol";
import "../../src/fundraising/ProjectToken.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockProjectRegistry.sol";
import "../mocks/MockBondingCurveStrategyRegistry.sol";

// This base contract sets up the entire factory infrastructure needed for deployment.
contract FuzzTestBase is Test {
    BondingCurveFactory internal factory;
    MockBondingCurveStrategyRegistry internal registry;
    MockProjectRegistry internal projectRegistry;
    MockERC20 internal collateralToken;

    address internal projectOwner = address(0x1);
    address internal fuzzer = address(this);

    uint256 internal constant TEAM_ALLOCATION = 1000e18;
    uint256 internal constant INITIAL_FUZZER_BALANCE = 1_000_000_000e18;
    uint256 internal constant VESTING_CLIFF_SECONDS = 30 days;
    uint256 internal constant VESTING_DURATION_SECONDS = 365 days;
    uint256 internal constant MAX_WITHDRAWAL_PERCENTAGE = 1500;
    uint256 internal constant WITHDRAWAL_FREQUENCY = 7 days;

    function _setUpFuzzingInfrastructure() internal {
        collateralToken = new MockERC20("Collateral", "COL", 18);
        projectRegistry = new MockProjectRegistry();
        registry = new MockBondingCurveStrategyRegistry();

        factory = new BondingCurveFactory(address(projectRegistry), address(registry), address(collateralToken));

        // Fund the fuzzer (the test contract itself)
        collateralToken.mint(fuzzer, INITIAL_FUZZER_BALANCE);
    }
}

contract ExponentialCurveFuzzTest is FuzzTestBase {
    ExponentialCurve internal curve;
    ProjectToken internal projectToken;
    bytes32 internal constant PROJECT_ID = keccak256("FUZZ_EXP");
    uint256 internal constant PRICE_COEFFICIENT = 1;

    function setUp() public {
        _setUpFuzzingInfrastructure();

        // Deploy and register the implementation
        ExponentialCurve implementation = new ExponentialCurve();
        bytes32 strategyId = keccak256("EXP_FUZZ_V1");
        registry.addStrategy(strategyId, address(implementation));

        // Setup project in registry
        projectRegistry.addProject(PROJECT_ID, projectOwner);
        projectRegistry.setProjectStatus(PROJECT_ID, IProjectRegistry.ProjectStatus.Active);

        // Prepare initialization data
        bytes memory initData = abi.encode(
            PRICE_COEFFICIENT,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            MAX_WITHDRAWAL_PERCENTAGE,
            WITHDRAWAL_FREQUENCY
        );

        // Deploy the curve via the factory to get the proxy
        bytes memory ammConfigData = abi.encode(false, 0, address(0), bytes32(0));
        BondingCurveParams memory params = BondingCurveParams({
            projectId: PROJECT_ID,
            strategyId: strategyId,
            tokenName: "Fuzz",
            tokenSymbol: "FUZ",
            strategyInitializationData: initData,
            ammConfigData: ammConfigData
        });
        address curveAddress = factory.createBondingCurve(params);

        // Point our test variables to the deployed proxy and its token
        curve = ExponentialCurve(payable(curveAddress));
        projectToken = ProjectToken(curve.projectToken());

        // Fuzzer approves the curve proxy to move its tokens
        vm.prank(fuzzer);
        collateralToken.approve(address(curve), type(uint256).max);
        vm.prank(fuzzer);
        projectToken.approve(address(curve), type(uint256).max);
    }

    // Fuzz test function with "test" prefix
    function test_stateful_buyAndSell(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        if (projectToken.balanceOf(fuzzer) < amount || amount % 2 == 0) {
            buy(amount);
        } else {
            sell(amount);
        }
        assertInvariants();
    }

    function buy(uint256 amount) internal {
        try curve.getBuyPrice(amount) returns (uint256 price) {
            if (price > collateralToken.balanceOf(fuzzer)) return;
            vm.prank(fuzzer);
            curve.buy(amount, price);
        } catch {
            return;
        }
    }

    function sell(uint256 amount) internal {
        uint256 bal = projectToken.balanceOf(fuzzer);
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        vm.prank(fuzzer);
        curve.sell(amount, 0);
    }

    function assertInvariants() internal view {
        uint256 supply = projectToken.totalSupply() - TEAM_ALLOCATION;
        if (supply > 0) {
            uint256 requiredCollateral = curve.getSellPrice(supply);
            assertGe(
                collateralToken.balanceOf(address(curve)),
                requiredCollateral,
                "Invariant Violated: Collateral backing is insufficient"
            );
        }
        assertTrue(
            projectToken.totalSupply() >= TEAM_ALLOCATION, "Invariant Violated: Supply dropped below team allocation"
        );
    }
}

contract LogarithmicCurveFuzzTest is FuzzTestBase {
    LogarithmicCurve internal curve;
    ProjectToken internal projectToken;
    bytes32 internal constant PROJECT_ID = keccak256("FUZZ_LOG");
    uint256 internal constant PRICE_COEFFICIENT = 1e18;

    function setUp() public {
        _setUpFuzzingInfrastructure();

        // Deploy and register the implementation
        LogarithmicCurve implementation = new LogarithmicCurve();
        bytes32 strategyId = keccak256("LOG_FUZZ_V1");
        registry.addStrategy(strategyId, address(implementation));

        // Setup project in registry
        projectRegistry.addProject(PROJECT_ID, projectOwner);
        projectRegistry.setProjectStatus(PROJECT_ID, IProjectRegistry.ProjectStatus.Active);

        // Prepare initialization data
        bytes memory initData = abi.encode(
            PRICE_COEFFICIENT,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            MAX_WITHDRAWAL_PERCENTAGE,
            WITHDRAWAL_FREQUENCY
        );

        // Deploy the curve via the factory to get the proxy
        bytes memory ammConfigData = abi.encode(false, 0, address(0), bytes32(0));
        BondingCurveParams memory params = BondingCurveParams({
            projectId: PROJECT_ID,
            strategyId: strategyId,
            tokenName: "Fuzz",
            tokenSymbol: "FUZ",
            strategyInitializationData: initData,
            ammConfigData: ammConfigData
        });
        address curveAddress = factory.createBondingCurve(params);

        // Point our test variables to the deployed proxy and its token
        curve = LogarithmicCurve(payable(curveAddress));
        projectToken = ProjectToken(curve.projectToken());

        // Fuzzer approves the curve proxy to move its tokens
        vm.prank(fuzzer);
        collateralToken.approve(address(curve), type(uint256).max);
        vm.prank(fuzzer);
        projectToken.approve(address(curve), type(uint256).max);
    }

    function buy(uint256 amount) internal {
        try curve.getBuyPrice(amount) returns (uint256 price) {
            if (price > collateralToken.balanceOf(fuzzer)) return;
            vm.prank(fuzzer);
            curve.buy(amount, price);
        } catch {
            return;
        }
    }

    function sell(uint256 amount) internal {
        uint256 bal = projectToken.balanceOf(fuzzer);
        if (amount > bal) amount = bal;
        if (amount == 0) return;

        vm.prank(fuzzer);
        curve.sell(amount, 0);
    }

    function assertInvariants() internal view {
        uint256 supply = projectToken.totalSupply() - TEAM_ALLOCATION;
        if (supply > 0) {
            uint256 requiredCollateral = curve.getSellPrice(supply);
            assertGe(
                collateralToken.balanceOf(address(curve)),
                requiredCollateral,
                "Invariant Violated: Collateral backing is insufficient"
            );
        }
        assertTrue(
            projectToken.totalSupply() >= TEAM_ALLOCATION, "Invariant Violated: Supply dropped below team allocation"
        );
    }
}
