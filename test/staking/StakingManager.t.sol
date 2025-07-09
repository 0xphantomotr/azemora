// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/staking/StakingManager.sol";
import "../mocks/MockERC20.sol";

contract StakingManagerTest is Test {
    // --- Contracts ---
    StakingManager internal stakingManager;
    MockERC20 internal aztToken;

    // --- Users ---
    address internal admin;
    address internal rewardAdmin;
    address internal slasher;
    address internal user1;
    address internal user2;

    // --- Constants ---
    uint256 internal constant UNSTAKING_COOLDOWN = 7 days;

    function setUp() public {
        admin = makeAddr("admin");
        rewardAdmin = makeAddr("rewardAdmin");
        slasher = makeAddr("slasher");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.startPrank(admin);

        // --- Deploy Mocks ---
        aztToken = new MockERC20("Azemora Token", "AZT", 18);

        // --- Deploy and Initialize StakingManager ---
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

        vm.stopPrank();

        // --- Setup User State ---
        aztToken.mint(user1, 1000 * 1e18);
        aztToken.mint(user2, 1000 * 1e18);
    }

    /// @notice A helper function to stake for a user.
    function _stake(address user, uint256 amount) internal {
        vm.startPrank(user);
        aztToken.approve(address(stakingManager), amount);
        stakingManager.stake(amount);
        vm.stopPrank();
    }

    /// @notice Tests that the slash function correctly devalues all shares proportionally.
    function test_slash_reduces_token_value_proportionally() public {
        // --- Setup ---
        uint256 user1Stake = 100 * 1e18;
        uint256 user2Stake = 300 * 1e18;
        _stake(user1, user1Stake);
        _stake(user2, user2Stake);

        uint256 totalStaked = user1Stake + user2Stake;
        assertEq(aztToken.balanceOf(address(stakingManager)), totalStaked);

        uint256 user1Shares = stakingManager.sharesOf(user1);
        uint256 user2Shares = stakingManager.sharesOf(user2);

        // --- Action ---
        uint256 slashAmount = 40 * 1e18; // Slash 10% of the total pool
        vm.prank(slasher);
        stakingManager.slash(slashAmount, address(this)); // Send slashed funds to the test contract

        // --- Assertions ---
        // 1. Check total balance of the staking contract
        assertEq(aztToken.balanceOf(address(stakingManager)), totalStaked - slashAmount);

        // 2. Check that user shares have not changed
        assertEq(stakingManager.sharesOf(user1), user1Shares);
        assertEq(stakingManager.sharesOf(user2), user2Shares);

        // 3. Check that the token value of those shares has decreased
        uint256 user1ValueAfterSlash = stakingManager.sharesToTokens(user1Shares);
        uint256 user2ValueAfterSlash = stakingManager.sharesToTokens(user2Shares);

        // user1's stake should be 100 - (10% of 100) = 90
        assertApproxEqAbs(user1ValueAfterSlash, 90 * 1e18, 1);
        // user2's stake should be 300 - (10% of 300) = 270
        assertApproxEqAbs(user2ValueAfterSlash, 270 * 1e18, 1);
    }

    /// @notice Tests that the unstaking cooldown and withdrawal process works as intended.
    function test_unstake_cooldown_and_withdrawal() public {
        // --- Setup ---
        uint256 stakeAmount = 200 * 1e18;
        _stake(user1, stakeAmount);
        uint256 user1Shares = stakingManager.sharesOf(user1);

        // --- Initiate Unstake ---
        vm.startPrank(user1);
        stakingManager.initiateUnstake(user1Shares);

        // --- Assertions for cooldown period ---
        // 1. Cannot withdraw immediately
        vm.expectRevert(StakingManager__WithdrawalNotReady.selector);
        stakingManager.withdraw();

        // 2. User's active shares are zero (they don't earn rewards during cooldown)
        assertEq(stakingManager.sharesOf(user1), 0);

        // --- Assertions after cooldown period ---
        // 1. Warp time past the cooldown
        vm.warp(block.timestamp + UNSTAKING_COOLDOWN + 1);

        // 2. Withdraw now succeeds
        uint256 user1InitialBalance = aztToken.balanceOf(user1);
        stakingManager.withdraw();
        uint256 user1FinalBalance = aztToken.balanceOf(user1);

        assertEq(user1FinalBalance - user1InitialBalance, stakeAmount, "User should receive their staked tokens back");
        vm.stopPrank();
    }

    /// @notice Tests that only an address with SLASHER_ROLE can call slash.
    function test_revert_slash_if_not_slasher_role() public {
        _stake(user1, 100 * 1e18);

        // An unauthorized user attempts to slash
        vm.startPrank(user2);
        bytes32 slasherRole = stakingManager.SLASHER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), user2, slasherRole
            )
        );
        stakingManager.slash(10 * 1e18, user2);
        vm.stopPrank();
    }
}
