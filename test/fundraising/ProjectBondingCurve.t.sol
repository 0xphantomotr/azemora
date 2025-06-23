// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {
    ProjectBondingCurve,
    ProjectBondingCurve__VestingNotStarted,
    ProjectBondingCurve__NothingToClaim,
    ProjectBondingCurve__WithdrawalTooSoon,
    ProjectBondingCurve__WithdrawalLimitExceeded,
    ProjectBondingCurve__InvalidParameter,
    ProjectBondingCurve__SlippageExceeded,
    ProjectBondingCurve__InsufficientBalance
} from "../../src/fundraising/ProjectBondingCurve.sol";
import {ProjectToken} from "../../src/fundraising/ProjectToken.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ProjectBondingCurveUnitTest is Test {
    // --- Constants ---
    uint256 public constant WAD = 1e18;
    uint256 public constant SLOPE = 1e9;
    uint256 public constant TEAM_ALLOCATION = 1000 * WAD;
    uint256 public constant VESTING_CLIFF_SECONDS = 30 days;
    uint256 public constant VESTING_DURATION_SECONDS = 90 days;

    // --- Actors ---
    address public owner = makeAddr("owner");
    address public attacker = makeAddr("attacker");
    address public bob = makeAddr("bob");

    // --- Contracts ---
    ProjectBondingCurve public curve;
    ProjectToken public projectToken;
    MockCollateral public collateral;

    function setUp() public {
        // Deploy dependencies
        projectToken = new ProjectToken("Test Token", "TT", address(this));
        collateral = new MockCollateral();

        // Deploy the contract we are testing
        curve = new ProjectBondingCurve();

        // Transfer ownership of token to the curve
        projectToken.transferOwnership(address(curve));

        // Initialize the curve
        curve.initialize(
            address(projectToken),
            address(collateral),
            owner,
            SLOPE,
            TEAM_ALLOCATION,
            VESTING_CLIFF_SECONDS,
            VESTING_DURATION_SECONDS,
            1500, // maxWithdrawalPercentage
            7 days // withdrawalFrequency
        );
    }

    // =================================================================
    // Vesting Tests
    // =================================================================

    function test_Fail_ClaimBeforeCliff() public {
        // Warp time to just before the cliff ends
        vm.warp(block.timestamp + VESTING_CLIFF_SECONDS - 1);

        vm.startPrank(owner);
        vm.expectRevert(ProjectBondingCurve__VestingNotStarted.selector);
        curve.claimVestedTokens();
        vm.stopPrank();
    }

    function test_ClaimVestedTokens_Halfway() public {
        // Warp time to halfway through the total vesting period
        uint256 halfwayPoint = VESTING_CLIFF_SECONDS + ((VESTING_DURATION_SECONDS - VESTING_CLIFF_SECONDS) / 2);
        vm.warp(block.timestamp + halfwayPoint);

        // The vested amount should be proportional to the time elapsed since the start.
        uint256 timeElapsed = halfwayPoint;
        uint256 expectedVestedAmount = (TEAM_ALLOCATION * timeElapsed) / VESTING_DURATION_SECONDS;

        vm.startPrank(owner);
        uint256 claimedAmount = curve.claimVestedTokens();
        assertEq(claimedAmount, expectedVestedAmount, "Claimed amount at halfway point is incorrect");
        assertEq(projectToken.balanceOf(owner), expectedVestedAmount, "Owner token balance is incorrect");
        vm.stopPrank();
    }

    function test_ClaimVestedTokens_AfterEnd() public {
        // Warp time to after the vesting period is fully complete
        vm.warp(block.timestamp + VESTING_DURATION_SECONDS + 1);

        vm.startPrank(owner);
        uint256 claimedAmount = curve.claimVestedTokens();
        assertEq(claimedAmount, TEAM_ALLOCATION, "Should be able to claim the full allocation after duration");

        // Subsequent claims should yield nothing
        vm.expectRevert(ProjectBondingCurve__NothingToClaim.selector);
        curve.claimVestedTokens();
        vm.stopPrank();
    }

    function test_ClaimVestedTokens_Incrementally() public {
        vm.startPrank(owner);

        // 1. Claim exactly at the cliff
        vm.warp(block.timestamp + VESTING_CLIFF_SECONDS);
        uint256 expectedAtCliff = (TEAM_ALLOCATION * VESTING_CLIFF_SECONDS) / VESTING_DURATION_SECONDS;
        uint256 claimedAtCliff = curve.claimVestedTokens();
        assertEq(claimedAtCliff, expectedAtCliff, "Incorrect amount at cliff");

        // 2. Warp to the end and claim the rest
        vm.warp(block.timestamp + VESTING_DURATION_SECONDS); // No need to subtract, just go far forward
        uint256 remainingAmount = TEAM_ALLOCATION - expectedAtCliff;
        uint256 claimedRemainder = curve.claimVestedTokens();
        assertEq(claimedRemainder, remainingAmount, "Incorrect remaining amount claimed");

        // 3. Total balance should be the full allocation
        assertEq(projectToken.balanceOf(owner), TEAM_ALLOCATION, "Owner should have the full allocation");
        vm.stopPrank();
    }

    function test_Fail_ClaimByNonOwner() public {
        vm.warp(block.timestamp + VESTING_CLIFF_SECONDS); // Move past cliff

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        curve.claimVestedTokens();
        vm.stopPrank();
    }

    // =================================================================
    // Withdrawal Tests
    // =================================================================

    function test_Fail_Withdraw_WithNoCollateral() public {
        vm.startPrank(owner);
        // Warp time to be past the first frequency period
        vm.warp(block.timestamp + 7 days + 1);
        // Should fail because no funds have been deposited yet
        vm.expectRevert(ProjectBondingCurve__WithdrawalLimitExceeded.selector);
        curve.withdrawCollateral();
        vm.stopPrank();
    }

    function test_WithdrawCollateral_CorrectAmountAndFrequency() public {
        // Simulate a user buying tokens to populate collateral
        uint256 buyAmount = 100 * WAD;
        uint256 buyCost = curve.getBuyPrice(buyAmount);
        collateral.mint(address(this), buyCost);
        collateral.approve(address(curve), buyCost);
        curve.buy(buyAmount, buyCost);

        uint256 maxWithdrawalPercentage = curve.maxWithdrawalPercentage();
        uint256 withdrawalFrequency = curve.withdrawalFrequency();

        // --- First Withdrawal ---
        vm.startPrank(owner);

        // Fail before frequency period passes
        vm.warp(block.timestamp + withdrawalFrequency - 10);
        vm.expectRevert(ProjectBondingCurve__WithdrawalTooSoon.selector);
        curve.withdrawCollateral();

        // Succeed after frequency period passes
        vm.warp(block.timestamp + 11); // move 1 second past the period
        uint256 expectedWithdrawal = (buyCost * maxWithdrawalPercentage) / 10000;
        uint256 ownerBalanceBefore = collateral.balanceOf(owner);
        curve.withdrawCollateral();
        uint256 ownerBalanceAfter = collateral.balanceOf(owner);

        assertEq(ownerBalanceAfter - ownerBalanceBefore, expectedWithdrawal, "First withdrawal amount incorrect");
        assertEq(curve.collateralAvailableForWithdrawal(), 0, "Collateral for withdrawal not reset");

        // --- Second Withdrawal Attempt ---
        // Should fail immediately after, as timer has reset and no new collateral added
        vm.expectRevert(ProjectBondingCurve__WithdrawalTooSoon.selector);
        curve.withdrawCollateral();

        vm.stopPrank();
    }

    function test_Fail_WithdrawByNonOwner() public {
        // Simulate a buy to add collateral
        uint256 buyCost = curve.getBuyPrice(1 * WAD);
        collateral.mint(address(this), buyCost);
        collateral.approve(address(curve), buyCost);
        curve.buy(1 * WAD, buyCost);

        // Warp past the frequency period
        vm.warp(block.timestamp + 7 days + 1);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        curve.withdrawCollateral();
        vm.stopPrank();
    }

    // =================================================================
    // Buy/Sell Logic Tests
    // =================================================================

    function test_Fail_Buy_WithZeroAmount() public {
        vm.startPrank(bob);
        vm.expectRevert(ProjectBondingCurve__InvalidParameter.selector);
        curve.buy(0, 100);
        vm.stopPrank();
    }

    function test_Fail_Sell_WithZeroAmount() public {
        vm.startPrank(bob);
        vm.expectRevert(ProjectBondingCurve__InvalidParameter.selector);
        curve.sell(0, 0);
        vm.stopPrank();
    }

    function test_Fail_Buy_SlippageExceeded() public {
        uint256 buyAmount = 10 * WAD;
        uint256 actualCost = curve.getBuyPrice(buyAmount);

        // Bob tries to buy, but sets his max spend just 1 wei too low
        vm.startPrank(bob);
        collateral.mint(bob, actualCost);
        collateral.approve(address(curve), actualCost);

        vm.expectRevert(ProjectBondingCurve__SlippageExceeded.selector);
        curve.buy(buyAmount, actualCost - 1);
        vm.stopPrank();
    }

    function test_Fail_Sell_SlippageExceeded() public {
        // An address buys tokens first to give Bob something to sell
        uint256 buyAmount = 10 * WAD;
        uint256 buyCost = curve.getBuyPrice(buyAmount);
        collateral.mint(address(this), buyCost);
        collateral.approve(address(curve), buyCost);
        curve.buy(buyAmount, buyCost);
        projectToken.transfer(bob, buyAmount); // Give tokens to Bob

        // Bob tries to sell, but demands 1 wei more than he would get
        vm.startPrank(bob);
        uint256 actualProceeds = curve.getSellPrice(buyAmount);
        projectToken.approve(address(curve), buyAmount);

        vm.expectRevert(ProjectBondingCurve__SlippageExceeded.selector);
        curve.sell(buyAmount, actualProceeds + 1);
        vm.stopPrank();
    }

    function test_Fail_Sell_MoreThanBalance() public {
        // The test address buys tokens and sends half to Bob.
        uint256 buyAmount = 50 * WAD;
        uint256 buyCost = curve.getBuyPrice(buyAmount);
        collateral.mint(address(this), buyCost);
        collateral.approve(address(curve), buyCost);
        curve.buy(buyAmount, buyCost);
        projectToken.transfer(bob, buyAmount / 2);

        // Bob tries to sell more tokens than he owns
        vm.startPrank(bob);
        uint256 amountToSell = buyAmount; // more than his balance of buyAmount / 2
        projectToken.approve(address(curve), amountToSell);

        // Expect revert from the ERC20 contract itself
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, buyAmount / 2, amountToSell)
        );
        curve.sell(amountToSell, 0);
        vm.stopPrank();
    }

    function test_Fail_Sell_MoreThanCirculatingSupply() public {
        // The test address buys some tokens
        uint256 buyAmount = 50 * WAD;
        uint256 buyCost = curve.getBuyPrice(buyAmount);
        collateral.mint(address(this), buyCost);
        collateral.approve(address(curve), buyCost);
        curve.buy(buyAmount, buyCost);

        // It transfers the tokens to the owner, who will try to sell them.
        projectToken.transfer(owner, buyAmount);

        // Now the owner tries to sell more tokens than are in circulation
        vm.startPrank(owner);
        uint256 amountToSell = buyAmount + 1;
        projectToken.approve(address(curve), amountToSell);

        // This should be caught by our internal check before it hits the token contract
        vm.expectRevert(ProjectBondingCurve__InsufficientBalance.selector);
        curve.sell(amountToSell, 0);
        vm.stopPrank();
    }
}
