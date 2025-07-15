// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {StakingManager} from "../../src/staking/StakingManager.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title MockStakingToken
/// @dev A mock ERC20 token for the StakingManager test.
contract MockStakingToken is ERC20Upgradeable {
    function initialize() public initializer {
        __ERC20_init("Mock AZE", "mAZE");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title StakingManagerEchidnaTest
/// @notice Defines properties that should always hold true for the StakingManager contract.
contract StakingManagerEchidnaTest is Test {
    StakingManager internal stakingManager;
    MockStakingToken internal aztToken;

    // --- Actors ---
    address internal admin;
    address internal rewardAdmin;
    address internal slasher;
    address[] internal users;

    // --- State Tracking for Invariants ---
    mapping(address => uint256) public unstakeRequestAmounts;

    // --- Constants ---
    uint256 constant NUM_USERS = 4;
    uint256 constant INITIAL_USER_BALANCE = 1_000_000e18;
    uint256 constant UNSTAKING_COOLDOWN = 7 days;

    constructor() {
        // --- Create Actors ---
        admin = vm.addr(1);
        rewardAdmin = vm.addr(2);
        slasher = vm.addr(3);
        for (uint256 i = 0; i < NUM_USERS; i++) {
            users.push(vm.addr(uint256(keccak256(abi.encodePacked("user", i)))));
        }

        // --- Deploy & Configure Contracts ---
        aztToken = new MockStakingToken();
        aztToken.initialize();

        stakingManager = StakingManager(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new StakingManager()),
                        abi.encodeCall(
                            StakingManager.initialize,
                            (address(aztToken), admin, rewardAdmin, slasher, UNSTAKING_COOLDOWN)
                        )
                    )
                )
            )
        );

        // --- Fund Users & Admins ---
        for (uint256 i = 0; i < NUM_USERS; i++) {
            aztToken.mint(users[i], INITIAL_USER_BALANCE);
        }
        aztToken.mint(rewardAdmin, 10_000_000e18); // Fund reward admin for notifyRewardAmount calls
    }

    // =================================================================
    //                           INVARIANTS
    // =================================================================

    /// @dev Property: The sum of the token value of all user shares should equal the total staked amount.
    /// This is a strong invariant that checks for value loss due to precision errors, especially after a slash.
    function echidna_total_value_equals_total_staked() public view returns (bool) {
        uint256 totalShares = stakingManager.totalShares();
        if (totalShares == 0) {
            return true; // No shares, nothing to check
        }

        uint256 totalStaked = stakingManager.totalStaked();
        uint256 sumOfShareValues = 0;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 userShares = stakingManager.sharesOf(user);
            if (userShares > 0) {
                sumOfShareValues += stakingManager.sharesToTokens(userShares);
            }
        }

        // The sum of the value of the parts must equal the whole.
        // Allow a small discrepancy for dust, at most 1 wei per user, which can accumulate.
        uint256 difference =
            sumOfShareValues > totalStaked ? sumOfShareValues - totalStaked : totalStaked - sumOfShareValues;

        if (difference > users.length) {
            return false;
        }
        return true;
    }

    /// @dev Property: The contract must always have enough tokens to cover the principal staked by users.
    function echidna_solvency() public view returns (bool) {
        uint256 contractBalance = aztToken.balanceOf(address(stakingManager));
        uint256 totalPrincipalStaked = stakingManager.totalStaked();

        // The contract's balance must be able to cover all principal stakes.
        // It can be greater due to holding rewards.
        if (contractBalance < totalPrincipalStaked) {
            return false;
        }
        return true;
    }

    /// @dev Property: After an unstake is initiated, the promised withdrawal amount must be honored.
    function echidna_unstake_request_is_honored() public view returns (bool) {
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            (uint256 amount, uint256 releaseTime) = stakingManager.unstakeRequests(user);

            // If a user has an active unstake request...
            if (amount > 0) {
                // ...the amount recorded in our state tracker must match the contract's view.
                if (unstakeRequestAmounts[user] != amount) {
                    return false;
                }
            }
        }
        return true;
    }

    // =================================================================
    //                      STATE-CHANGING FUNCTIONS
    // =================================================================

    function stake(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        uint256 userBalance = aztToken.balanceOf(user);
        if (userBalance == 0) return;

        uint256 amount = (seed % userBalance) + 1;

        vm.startPrank(user);
        aztToken.approve(address(stakingManager), amount);
        stakingManager.stake(amount);
        vm.stopPrank();
    }

    function initiateUnstake(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        uint256 userShares = stakingManager.sharesOf(user);
        if (userShares == 0) return;

        uint256 sharesToUnstake = (seed % userShares) + 1;

        // Predict the token amount *before* the transaction
        uint256 tokensToWithdraw = stakingManager.sharesToTokens(sharesToUnstake);

        // Update our state tracker
        unstakeRequestAmounts[user] += tokensToWithdraw;

        vm.startPrank(user);
        stakingManager.initiateUnstake(sharesToUnstake);
        vm.stopPrank();
    }

    function withdraw(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        (uint256 amount, uint256 releaseTime) = stakingManager.unstakeRequests(user);
        if (amount == 0 || block.timestamp < releaseTime) return;

        // Clear the state tracker as the request is now fulfilled.
        unstakeRequestAmounts[user] = 0;

        vm.prank(user);
        stakingManager.withdraw();
    }

    function compound(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        if (stakingManager.earned(user) == 0) return;
        vm.prank(user);
        stakingManager.compound();
    }

    function claimReward(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        if (stakingManager.earned(user) == 0) return;
        vm.prank(user);
        stakingManager.claimReward();
    }

    function notifyRewardAmount(uint256 seed) public {
        uint256 rewardAdminBalance = aztToken.balanceOf(rewardAdmin);
        if (rewardAdminBalance == 0) return;

        uint256 rewardAmount = (seed % rewardAdminBalance) + 1;
        uint256 duration = (seed % (90 days)) + 1 days; // Duration from 1 to 91 days

        vm.startPrank(rewardAdmin);
        aztToken.approve(address(stakingManager), rewardAmount);
        stakingManager.notifyRewardAmount(rewardAmount, duration);
        vm.stopPrank();
    }

    function slash(uint256 seed) public {
        uint256 totalStaked = stakingManager.totalStaked();
        if (totalStaked == 0) return;

        uint256 slashAmount = (seed % totalStaked) + 1;
        address compensationTarget = users[seed % NUM_USERS];

        vm.prank(slasher);
        stakingManager.slash(slashAmount, compensationTarget);
    }

    function warpTime(uint256 seed) public {
        // Warp forward between 1 second and the full unstaking cooldown
        uint256 time = (seed % (UNSTAKING_COOLDOWN * 2)) + 1;
        vm.warp(block.timestamp + time);
    }
}
