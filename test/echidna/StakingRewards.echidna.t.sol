// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../../src/staking/StakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockAzeToken
/// @dev A simple mock ERC20 token for testing purposes.
contract MockAzeToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public constant name = "Mock AZE";
    string public constant symbol = "mAZE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

/// @title StakingRewardsEchidnaTest
/// @notice Defines properties that should always hold true for the StakingRewards contract.
contract StakingRewardsEchidnaTest is Test {
    StakingRewards internal stakingRewards;
    MockAzeToken internal azeToken;

    // --- Actors ---
    address internal owner;
    address[] internal users;

    // --- State Tracking for Invariants ---
    mapping(address => uint256) public userStakedBalances;
    uint256 public totalRewardsProvided;
    uint256 public totalRewardsPaidOut;

    // --- Constants ---
    uint256 constant NUM_USERS = 4;
    uint256 constant INITIAL_USER_BALANCE = 1_000_000e18;
    uint256 constant INITIAL_REWARD_POOL = 5_000_000e18;

    constructor() {
        // --- Create Actors ---
        owner = address(this);
        for (uint256 i = 0; i < NUM_USERS; i++) {
            users.push(vm.addr(uint256(keccak256(abi.encodePacked("user", i)))));
        }

        // --- Deploy & Configure Contracts ---
        azeToken = new MockAzeToken();
        stakingRewards = new StakingRewards(address(azeToken));

        // --- Fund Users & Reward Pool ---
        for (uint256 i = 0; i < NUM_USERS; i++) {
            azeToken.mint(users[i], INITIAL_USER_BALANCE);
        }
        azeToken.mint(owner, INITIAL_REWARD_POOL);

        // --- Initialize Reward State ---
        // Transfer initial rewards to the contract and notify it
        azeToken.transfer(address(stakingRewards), INITIAL_REWARD_POOL);
        totalRewardsProvided = INITIAL_REWARD_POOL;
        stakingRewards.notifyRewardAmount(INITIAL_REWARD_POOL, 365 days);
    }

    // =================================================================
    //                           INVARIANTS
    // =================================================================

    /// @dev Property: The total amount staked in the contract should equal the sum of all individual user stakes.
    function echidna_staked_token_is_conserved() public view returns (bool) {
        uint256 sumOfUserBalances = 0;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            // Check individual balance against contract's view
            if (userStakedBalances[user] != stakingRewards.balanceOf(user)) {
                return false;
            }
            sumOfUserBalances += userStakedBalances[user];
        }
        // Check sum of balances against contract's total supply
        if (sumOfUserBalances != stakingRewards.totalSupply()) {
            return false;
        }
        return true;
    }

    /// @dev Property: All reward tokens must be accounted for. The sum of rewards held by the contract
    /// and rewards paid out must equal the total rewards ever provided.
    function echidna_reward_token_is_conserved() public view returns (bool) {
        uint256 contractBalance = azeToken.balanceOf(address(stakingRewards));
        uint256 totalStaked = stakingRewards.totalSupply();

        // The rewards available in the contract is the total balance minus the principal staked by users.
        uint256 rewardsHeldInContract = contractBalance - totalStaked;

        // The sum of rewards still in the contract and rewards paid out should equal the total provided.
        uint256 totalAccountedFor = rewardsHeldInContract + totalRewardsPaidOut;

        // Note: Due to integer math precision, there can be tiny rounding differences over many operations.
        // We check that the difference is extremely small (less than the number of users),
        // which accounts for potential dust amounts left over from division.
        uint256 difference = totalAccountedFor > totalRewardsProvided
            ? totalAccountedFor - totalRewardsProvided
            : totalRewardsProvided - totalAccountedFor;

        if (difference > users.length) {
            // Allow a tiny dust amount per user
            return false;
        }
        return true;
    }

    // =================================================================
    //                      STATE-CHANGING FUNCTIONS
    // =================================================================

    function stake(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        uint256 userBalance = azeToken.balanceOf(user);
        if (userBalance == 0) return;

        uint256 amount = (seed % userBalance) + 1;

        userStakedBalances[user] += amount;

        vm.startPrank(user);
        azeToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);
        vm.stopPrank();
    }

    function unstake(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        uint256 stakedBalance = stakingRewards.balanceOf(user);
        if (stakedBalance == 0) return;

        uint256 amount = (seed % stakedBalance) + 1;

        userStakedBalances[user] -= amount;

        vm.prank(user);
        stakingRewards.unstake(amount);
    }

    function claimReward(uint256 seed) public {
        address user = users[seed % NUM_USERS];

        // --- Measure, Don't Predict ---
        // Instead of predicting the reward with `earned()`, we measure the actual
        // change in the user's balance after the transaction. This is more robust.
        uint256 balanceBefore = azeToken.balanceOf(user);

        vm.prank(user);
        stakingRewards.claimReward();

        uint256 balanceAfter = azeToken.balanceOf(user);
        uint256 rewardPaid = balanceAfter - balanceBefore;

        if (rewardPaid > 0) {
            totalRewardsPaidOut += rewardPaid;
        }
    }

    function notifyRewardAmount(uint256 seed) public {
        uint256 ownerBalance = azeToken.balanceOf(owner);
        if (ownerBalance == 0) return;

        uint256 rewardAmount = (seed % ownerBalance) + 1;
        uint256 duration = (seed % (365 days)) + 1 days; // Duration from 1 to 366 days

        totalRewardsProvided += rewardAmount;

        vm.startPrank(owner);
        azeToken.transfer(address(stakingRewards), rewardAmount);
        stakingRewards.notifyRewardAmount(rewardAmount, duration);
        vm.stopPrank();
    }

    function warpTime(uint256 seed) public {
        uint256 time = (seed % (365 days)) + 1; // Warp forward between 1 second and 365 days
        vm.warp(block.timestamp + time);
    }
}
