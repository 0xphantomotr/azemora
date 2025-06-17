// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/AzemoraToken.sol";
import "../../src/staking/StakingRewards.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StakingRewardsAdvancedTest is Test {
    // --- Contracts ---
    AzemoraToken azeToken;
    StakingRewards stakingRewards;

    // --- Actors ---
    address deployer = makeAddr("deployer");
    address staker = makeAddr("staker");

    // --- State for Invariant Testing ---
    address internal staker1;
    address internal staker2;
    address internal staker3;
    // Keep track of actors in an array for easy selection.
    address[] public stakers;

    // --- Setup ---
    function setUp() public {
        vm.startPrank(deployer);

        // Deploy AzemoraToken (implementation + proxy)
        AzemoraToken azeTokenImpl = new AzemoraToken();
        azeToken =
            AzemoraToken(address(new ERC1967Proxy(address(azeTokenImpl), abi.encodeCall(AzemoraToken.initialize, ()))));

        // Deploy StakingRewards
        stakingRewards = new StakingRewards(address(azeToken));

        // Fund all stakers with tokens from the deployer's balance
        azeToken.transfer(staker, 1_000_000e18);

        staker1 = makeAddr("staker1");
        staker2 = makeAddr("staker2");
        staker3 = makeAddr("staker3");
        azeToken.transfer(staker1, 1_000_000e18);
        azeToken.transfer(staker2, 1_000_000e18);
        azeToken.transfer(staker3, 1_000_000e18);

        vm.stopPrank();

        // Add actors for invariant testing
        stakers.push(staker1);
        stakers.push(staker2);
        stakers.push(staker3);
    }

    // --- Fuzz Tests ---

    /**
     * @notice Fuzz test to ensure stake/unstake accounting is correct.
     * @dev The test will stake a random amount and then immediately unstake it.
     * The staker's balance should be identical before and after.
     * We bound the amount to `type(uint96).max` which is a huge but not gas-breaking number.
     */
    function fuzz_StakeAndUnstake(uint96 amount) public {
        // Ensure the staker has enough tokens to perform the fuzz test
        // and that the amount is not zero.
        vm.assume(amount > 0 && amount < azeToken.balanceOf(staker));

        uint256 balanceBefore = azeToken.balanceOf(staker);

        vm.startPrank(staker);

        // Stake
        azeToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);

        assertEq(stakingRewards.balanceOf(staker), amount, "Staked amount should be recorded");

        // Unstake
        stakingRewards.unstake(amount);

        vm.stopPrank();

        uint256 balanceAfter = azeToken.balanceOf(staker);

        assertEq(balanceBefore, balanceAfter, "Balance should be unchanged after stake/unstake");
    }

    // --- Complex Scenario Tests ---

    /**
     * @notice Tests that a user who stakes after a reward period has started
     * only earns rewards proportional to their time staked.
     */
    function test_LateStaker_EarnsCorrectReward() public {
        uint256 stakeAmount = 100e18;
        uint256 rewardAmount = 1000e18;
        uint256 rewardDuration = 100; // seconds

        // 1. Staker 1 stakes at the beginning
        vm.startPrank(staker1);
        azeToken.approve(address(stakingRewards), stakeAmount);
        stakingRewards.stake(stakeAmount);
        vm.stopPrank();

        // 2. Owner adds rewards
        vm.startPrank(deployer);
        azeToken.transfer(address(stakingRewards), rewardAmount);
        stakingRewards.notifyRewardAmount(rewardAmount, rewardDuration);
        vm.stopPrank();

        // 3. Warp to the halfway point
        vm.warp(block.timestamp + (rewardDuration / 2));

        // 4. Staker 2 stakes halfway through the reward period
        vm.startPrank(staker2);
        azeToken.approve(address(stakingRewards), stakeAmount);
        stakingRewards.stake(stakeAmount);
        vm.stopPrank();

        // 5. Warp to the end of the reward period
        vm.warp(block.timestamp + (rewardDuration / 2));

        // 6. Check rewards.
        // Staker 1 was staked for 100% of the first half, and 50% of the second half.
        // Expected reward = (1 * 0.5 * rewardAmount) + (0.5 * 0.5 * rewardAmount) = 0.75 * rewardAmount
        uint256 staker1Reward = stakingRewards.earned(staker1);
        assertApproxEqAbs(staker1Reward, (rewardAmount * 3) / 4, 1e12, "Staker 1 reward incorrect");

        // Staker 2 was staked for 50% of the second half.
        // Expected reward = (0.5 * 0.5 * rewardAmount) = 0.25 * rewardAmount
        uint256 staker2Reward = stakingRewards.earned(staker2);
        assertApproxEqAbs(staker2Reward, rewardAmount / 4, 1e12, "Staker 2 reward incorrect");
    }

    // --- Invariant Setup & Stateful Fuzzing Actions ---
    // The functions below are the actions the fuzzer will call in random sequences.

    function stake(uint96 amount, uint256 stakerIndex) public {
        // Select a staker actor based on the fuzzed index
        address actor = stakers[stakerIndex % stakers.length];

        // Constrain the amount to be valid and reasonable
        uint96 maxStake = uint96(azeToken.balanceOf(actor));
        if (maxStake == 0) return;
        amount = uint96(bound(amount, 1, maxStake));

        vm.startPrank(actor);
        azeToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);
        vm.stopPrank();
    }

    function unstake(uint96 amount, uint256 stakerIndex) public {
        address actor = stakers[stakerIndex % stakers.length];

        uint256 currentStake = stakingRewards.balanceOf(actor);
        if (currentStake == 0) return; // Can't unstake if nothing is staked

        // Constrain the amount to be valid
        amount = uint96(bound(amount, 1, currentStake));

        vm.prank(actor);
        stakingRewards.unstake(amount);
    }

    function claim(uint256 stakerIndex) public {
        address actor = stakers[stakerIndex % stakers.length];
        vm.prank(actor);
        stakingRewards.claimReward();
    }

    function addRewards(uint128 reward, uint32 duration) public {
        // Constrain inputs to be reasonable
        duration = uint32(bound(duration, 1, 30 days));
        reward = uint128(bound(reward, 1, 1_000_000e18));

        // Owner adds rewards
        vm.startPrank(deployer);
        // Fund the contract with the reward amount
        azeToken.transfer(address(stakingRewards), reward);
        stakingRewards.notifyRewardAmount(reward, duration);
        vm.stopPrank();
    }

    function warp(uint32 time) public {
        // Advance time by a bounded amount to simulate passage of time for rewards
        vm.warp(block.timestamp + bound(time, 1, 30 days));
    }

    // --- Invariants ---

    // To run these, use `forge test --match-path test/staking/StakingRewardsAdvanced.t.sol -vv`
    // The fuzzer will try millions of combinations of the actions above to try and break these rules.

    function invariant_solvency() public view {
        // Calculate the total rewards owed to all users
        uint256 totalOwedRewards = 0;
        totalOwedRewards += stakingRewards.earned(staker);
        for (uint256 i = 0; i < stakers.length; i++) {
            totalOwedRewards += stakingRewards.earned(stakers[i]);
        }

        uint256 totalStaked = stakingRewards.totalSupply();
        uint256 contractBalance = azeToken.balanceOf(address(stakingRewards));

        // The contract's balance must always be enough to cover all staked tokens
        // plus all rewards earned so far. There might be some dust left over from
        // transfers or reward calculations, so we check for >=.
        assertTrue(
            contractBalance >= totalStaked + totalOwedRewards, "Solvency violated: Contract cannot pay its debts"
        );
    }

    function invariant_accounting() public view {
        // The sum of individual balances must equal the total supply
        uint256 sumOfBalances = 0;
        sumOfBalances += stakingRewards.balanceOf(staker);
        for (uint256 i = 0; i < stakers.length; i++) {
            sumOfBalances += stakingRewards.balanceOf(stakers[i]);
        }

        assertEq(sumOfBalances, stakingRewards.totalSupply(), "Accounting violated: Sum of balances != total supply");
    }
}
