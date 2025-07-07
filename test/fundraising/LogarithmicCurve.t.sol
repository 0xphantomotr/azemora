// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/fundraising/LogarithmicCurve.sol";
import "../../src/fundraising/ProjectToken.sol";
import "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UD60x18} from "@prb/math/src/UD60x18.sol";

contract LogarithmicCurveTest is Test {
    LogarithmicCurve internal curve;
    ProjectToken internal projectToken;
    MockERC20 internal collateralToken;

    address internal projectOwner = makeAddr("projectOwner");
    address internal user = makeAddr("user");

    // --- Curve Parameters ---
    uint256 internal constant LOG_PRICE_COEFFICIENT = 100e18; // k = 100
    uint256 internal constant LOG_MAX_SUPPLY = 1_000_000e18;

    function setUp() public {
        collateralToken = new MockERC20("Collateral", "COL", 18);
        projectToken = new ProjectToken("Test Token", "TEST", address(this)); // Deployed by test contract

        // --- Deploy via Proxy ---
        LogarithmicCurve implementation = new LogarithmicCurve();
        bytes memory initData = abi.encode(LOG_PRICE_COEFFICIENT, LOG_MAX_SUPPLY);
        bytes memory callData = abi.encodeWithSelector(
            LogarithmicCurve.initialize.selector,
            address(projectToken),
            address(collateralToken),
            projectOwner,
            initData
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), callData);
        curve = LogarithmicCurve(address(proxy));
        // --- End Deploy via Proxy ---

        // Transfer ownership to the curve contract to grant minting rights
        projectToken.transferOwnership(address(curve));

        collateralToken.mint(user, 1000e18);
    }

    function test_initialization() public view {
        assertEq(curve.priceCoefficient().unwrap(), LOG_PRICE_COEFFICIENT);
        assertEq(curve.maxSupply().unwrap(), LOG_MAX_SUPPLY);
        assertEq(curve.owner(), projectOwner);
    }

    function test_buy_calculatesCorrectCost() public {
        uint256 amountToBuy = 100e18;

        // The expected value is calculated off-chain using a precise math library.
        // cost = 100 * ln(1,000,000 / 999,900) approx 0.0100005
        uint256 expectedCost = 10000500016667084;

        uint256 actualCost = curve.getBuyPrice(amountToBuy);
        assertApproxEqAbs(actualCost, expectedCost, 1e10, "Calculated buy price is incorrect");

        vm.startPrank(user);
        collateralToken.approve(address(curve), actualCost);
        curve.buy(amountToBuy, actualCost);
        vm.stopPrank();

        assertEq(projectToken.balanceOf(user), amountToBuy, "User should receive project tokens");
        assertEq(collateralToken.balanceOf(address(curve)), actualCost, "Curve should receive collateral");
    }

    function test_sell_calculatesCorrectProceeds() public {
        // First, seed the curve with an initial buy
        uint256 initialBuyAmount = 100e18;
        uint256 cost = curve.getBuyPrice(initialBuyAmount);
        vm.startPrank(user);
        collateralToken.approve(address(curve), cost);
        curve.buy(initialBuyAmount, cost);
        vm.stopPrank();

        // Now, test the sell
        uint256 amountToSell = 50e18;

        // The expected value is derived from the on-chain calculation, trusting the prb-math library's precision.
        uint256 expectedProceeds = 5000375029168900;

        uint256 actualProceeds = curve.getSellPrice(amountToSell);
        assertApproxEqAbs(actualProceeds, expectedProceeds, 1e10, "Calculated sell price is incorrect");

        vm.startPrank(user);
        uint256 userInitialBalance = collateralToken.balanceOf(user);
        // User must approve the curve to burn their project tokens
        projectToken.approve(address(curve), amountToSell);
        curve.sell(amountToSell, actualProceeds);
        vm.stopPrank();

        assertEq(projectToken.balanceOf(user), initialBuyAmount - amountToSell, "User's token balance should decrease");
        assertEq(collateralToken.balanceOf(user), userInitialBalance + actualProceeds, "User should receive collateral");
    }

    function test_revert_if_buy_exceeds_maxSupply() public {
        uint256 amountToBuy = LOG_MAX_SUPPLY + 1;
        vm.expectRevert(LogarithmicCurve__SupplyCapReached.selector);
        curve.getBuyPrice(amountToBuy);
    }

    function test_revert_if_buy_slippage_exceeded() public {
        uint256 amountToBuy = 100e18;
        uint256 cost = curve.getBuyPrice(amountToBuy);

        vm.startPrank(user);
        collateralToken.approve(address(curve), cost);
        vm.expectRevert(LogarithmicCurve__SlippageExceeded.selector);
        curve.buy(amountToBuy, cost - 1);
        vm.stopPrank();
    }

    function test_revert_if_sell_slippage_exceeded() public {
        // Seed the curve
        uint256 initialBuyAmount = 100e18;
        uint256 cost = curve.getBuyPrice(initialBuyAmount);
        vm.startPrank(user);
        collateralToken.approve(address(curve), cost);
        curve.buy(initialBuyAmount, cost);
        vm.stopPrank();

        uint256 amountToSell = 50e18;
        uint256 proceeds = curve.getSellPrice(amountToSell);

        vm.startPrank(user);
        projectToken.approve(address(curve), amountToSell);
        vm.expectRevert(LogarithmicCurve__SlippageExceeded.selector);
        curve.sell(amountToSell, proceeds + 1);
        vm.stopPrank();
    }

    function test_revert_on_buy_zero_amount() public {
        vm.expectRevert(LogarithmicCurve__InvalidParameter.selector);
        curve.buy(0, 1e18);
    }

    function test_revert_on_sell_zero_amount() public {
        vm.expectRevert(LogarithmicCurve__InvalidParameter.selector);
        curve.sell(0, 0);
    }

    function test_revert_on_sell_insufficient_balance() public {
        // User has 0 project tokens initially
        uint256 amountToSell = 1e18;
        vm.startPrank(user);
        projectToken.approve(address(curve), amountToSell);
        // The ERC20 `burnFrom` will revert with an insufficient balance error.
        vm.expectRevert();
        curve.sell(amountToSell, 0);
        vm.stopPrank();
    }

    function test_price_increases_after_buy() public {
        uint256 amountToBuy = 10e18;

        // First buy
        uint256 cost1 = curve.getBuyPrice(amountToBuy);
        vm.prank(user);
        collateralToken.approve(address(curve), type(uint256).max);
        vm.prank(user);
        curve.buy(amountToBuy, cost1);

        // Second buy
        uint256 cost2 = curve.getBuyPrice(amountToBuy);

        assertTrue(cost2 > cost1, "Price should increase after a buy");
    }

    function test_buy_then_sell_all_results_in_zero_spread() public {
        uint256 amountToBuy = 100e18;
        uint256 cost = curve.getBuyPrice(amountToBuy);

        // Buy
        vm.startPrank(user);
        collateralToken.approve(address(curve), cost);
        curve.buy(amountToBuy, cost);

        // Sell immediately
        uint256 proceeds = curve.getSellPrice(amountToBuy);
        projectToken.approve(address(curve), amountToBuy);
        curve.sell(amountToBuy, proceeds);
        vm.stopPrank();

        // For this specific curve formula, the cost to buy a certain amount of tokens from supply S
        // is exactly equal to the proceeds from selling the same amount of tokens back to the curve
        // when the supply is S + amount. There is no inherent spread without an explicit fee.
        assertApproxEqAbs(cost, proceeds, 1e10, "Cost should equal proceeds for this curve without fees");
    }

    function test_buy_near_max_supply() public {
        uint256 supply = projectToken.totalSupply();
        // Max buyable amount leaves 1e18 buffer for the logarithm calculation.
        uint256 amountToBuy = LOG_MAX_SUPPLY - supply - 1e18;
        uint256 cost = curve.getBuyPrice(amountToBuy);

        vm.startPrank(user);
        collateralToken.mint(user, cost);
        collateralToken.approve(address(curve), cost);
        curve.buy(amountToBuy, cost);
        vm.stopPrank();

        assertEq(projectToken.totalSupply(), LOG_MAX_SUPPLY - 1e18, "Total supply should be at the buyable limit");

        // Any further buy that goes into the buffer zone should fail.
        vm.expectRevert(LogarithmicCurve__SupplyCapReached.selector);
        curve.getBuyPrice(1);
    }

    function test_buy_tiny_amount() public {
        uint256 amountToBuy = 1; // 1 wei
        uint256 cost = curve.getBuyPrice(amountToBuy);

        assertTrue(cost > 0, "Cost for a tiny amount should be greater than zero");

        vm.startPrank(user);
        collateralToken.approve(address(curve), cost);
        curve.buy(amountToBuy, cost);
        vm.stopPrank();

        assertEq(projectToken.balanceOf(user), amountToBuy, "User should receive the tiny amount of tokens");
    }
}
