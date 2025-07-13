// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/staking/StakingManager.sol";
import "../../src/token/AzemoraToken.sol";

contract StakingManagerTest is Test {
    // --- Contracts ---
    StakingManager internal stakingManager;
    AzemoraToken internal aztToken;

    // --- Users ---
    address internal admin;
    address internal rewardAdmin;
    address internal slasher;
    address internal user1;
    uint256 internal user1Pk;
    address internal user2;
    uint256 internal user2Pk;

    // --- Constants ---
    uint256 internal constant UNSTAKING_COOLDOWN = 7 days;

    function setUp() public {
        admin = makeAddr("admin");
        rewardAdmin = makeAddr("rewardAdmin");
        slasher = makeAddr("slasher");
        // Use addresses with known private keys for users who will sign transactions
        user1Pk = 0x123;
        user1 = vm.addr(user1Pk);
        user2Pk = 0x456;
        user2 = vm.addr(user2Pk);

        // Deploy AzemoraToken behind a proxy
        aztToken = AzemoraToken(
            payable(address(new ERC1967Proxy(address(new AzemoraToken()), abi.encodeCall(AzemoraToken.initialize, ()))))
        );

        // The admin of the token is the test contract by default.
        // We need to transfer some tokens to our users.
        aztToken.transfer(user1, 1000 * 1e18);
        aztToken.transfer(user2, 1000 * 1e18);
        aztToken.transfer(rewardAdmin, 1000 * 1e18);

        vm.startPrank(admin);

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
    }

    /// @notice A helper function to stake for a user.
    function _stake(address user, uint256 amount) internal {
        vm.startPrank(user);
        aztToken.approve(address(stakingManager), amount);
        stakingManager.stake(amount);
        vm.stopPrank();
    }

    function test_stake_succeeds() public {
        uint256 stakeAmount = 100 * 1e18;
        _stake(user1, stakeAmount);
        assertEq(stakingManager.sharesOf(user1), stakeAmount, "User should have staked shares");
    }

    function test_stakeWithPermit_succeeds_with_valid_signature() public {
        uint256 stakeAmount = 100 * 1e18;
        uint256 deadline = block.timestamp + 1 days;
        uint256 user1Nonce = aztToken.nonces(user1);

        // 1. Craft the digest to be signed
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                aztToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        user1,
                        address(stakingManager),
                        stakeAmount,
                        user1Nonce,
                        deadline
                    )
                )
            )
        );

        // 2. Sign the digest with the user's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, digest);

        // 3. Call stakeWithPermit
        vm.prank(user1);
        stakingManager.stakeWithPermit(stakeAmount, deadline, v, r, s);

        // 4. Assert that the stake was successful
        assertEq(stakingManager.sharesOf(user1), stakeAmount, "User should have staked shares after stakeWithPermit");
        assertEq(aztToken.balanceOf(address(stakingManager)), stakeAmount, "StakingManager should have the tokens");
    }

    function test_compound_reinvests_rewards() public {
        // 1. Setup: User stakes and rewards are added to the pool
        uint256 initialStake = 100 * 1e18;
        _stake(user1, initialStake);

        uint256 rewardAmount = 10 * 1e18;
        vm.startPrank(rewardAdmin);
        aztToken.approve(address(stakingManager), rewardAmount);
        stakingManager.notifyRewardAmount(rewardAmount, 100 seconds); // 10 tokens over 100 seconds
        vm.stopPrank();

        // 2. Action: Advance time to accrue rewards, then compound
        vm.warp(block.timestamp + 10 seconds);

        uint256 rewardsEarned = stakingManager.earned(user1);
        assertTrue(rewardsEarned > 0, "User should have earned rewards");

        uint256 sharesBefore = stakingManager.sharesOf(user1);
        uint256 contractBalanceBefore = aztToken.balanceOf(address(stakingManager));

        vm.prank(user1);
        stakingManager.compound();

        // 3. Assertions
        uint256 sharesAfter = stakingManager.sharesOf(user1);
        uint256 contractBalanceAfter = aztToken.balanceOf(address(stakingManager));

        assertTrue(sharesAfter > sharesBefore, "Shares should increase after compounding");
        assertEq(stakingManager.earned(user1), 0, "Pending rewards should be zero after compounding");
        assertEq(contractBalanceAfter, contractBalanceBefore, "No tokens should leave the contract on compound");

        // 4. Verify the value of the new shares
        uint256 tokenValueAfter = stakingManager.sharesToTokens(sharesAfter);
        assertApproxEqAbs(
            tokenValueAfter,
            initialStake + rewardsEarned,
            1,
            "Token value of shares should equal initial stake + compounded rewards"
        );
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

    /// @notice Tests that the unstaking cooldown and withdrawal process works as intended,
    ///         and that rewards are claimed automatically upon unstake initiation.
    function test_unstake_cooldown_and_withdrawal() public {
        // --- Setup: Stake and add rewards ---
        uint256 stakeAmount = 200 * 1e18;
        _stake(user1, stakeAmount);
        uint256 user1Shares = stakingManager.sharesOf(user1);

        uint256 rewardAmount = 20 * 1e18;
        vm.startPrank(rewardAdmin);
        aztToken.approve(address(stakingManager), rewardAmount);
        stakingManager.notifyRewardAmount(rewardAmount, 100 seconds);
        vm.stopPrank();

        // --- Action: Advance time and initiate unstake ---
        vm.warp(block.timestamp + 50 seconds); // Accrue half the rewards

        uint256 rewardsEarned = stakingManager.earned(user1);
        assertTrue(rewardsEarned > 0, "User should have earned some rewards");

        uint256 balanceBeforeUnstake = aztToken.balanceOf(user1);

        vm.startPrank(user1);
        stakingManager.initiateUnstake(user1Shares);

        // --- Assertions for immediate effects ---
        // 1. Check that rewards were paid out
        uint256 balanceAfterUnstake = aztToken.balanceOf(user1);
        assertApproxEqAbs(
            balanceAfterUnstake - balanceBeforeUnstake,
            rewardsEarned,
            1,
            "User should receive their pending rewards upon initiating unstake"
        );

        // 2. Cannot withdraw immediately (cooldown)
        vm.expectRevert(StakingManager__WithdrawalNotReady.selector);
        stakingManager.withdraw();

        // 3. User's active shares are zero
        assertEq(stakingManager.sharesOf(user1), 0, "User's active shares should be zero");

        // --- Assertions after cooldown period ---
        vm.warp(block.timestamp + UNSTAKING_COOLDOWN + 1);

        uint256 balanceBeforeWithdraw = aztToken.balanceOf(user1);
        stakingManager.withdraw();
        uint256 balanceAfterWithdraw = aztToken.balanceOf(user1);

        assertApproxEqAbs(
            balanceAfterWithdraw - balanceBeforeWithdraw,
            stakeAmount,
            1,
            "User should receive their staked tokens back after cooldown"
        );
        vm.stopPrank();
    }

    function test_initiateUnstake_succeeds_with_zero_rewards() public {
        // --- Setup ---
        uint256 stakeAmount = 100 * 1e18;
        _stake(user1, stakeAmount);
        uint256 user1Shares = stakingManager.sharesOf(user1);

        // --- Action ---
        // Immediately initiate unstake, with no time for rewards to accrue
        vm.startPrank(user1);
        stakingManager.initiateUnstake(user1Shares);
        vm.stopPrank();

        // --- Assertions ---
        (uint256 requestedAmount, uint256 releaseTime) = stakingManager.unstakeRequests(user1);
        assertEq(requestedAmount, stakeAmount, "Requested amount should equal the initial stake value");
        assertTrue(releaseTime > block.timestamp, "Release time should be in the future");
    }

    function test_initiateUnstake_multiple_times_aggregates_and_resets_cooldown() public {
        // --- Setup ---
        uint256 stakeAmount = 300 * 1e18;
        _stake(user1, stakeAmount);

        // --- Action 1: First unstake request ---
        uint256 sharesToUnstake1 = stakingManager.tokensToShares(100 * 1e18);
        vm.startPrank(user1);
        stakingManager.initiateUnstake(sharesToUnstake1);
        vm.stopPrank();

        // --- Assertions 1 ---
        (uint256 requestedAmount1, uint256 releaseTime1) = stakingManager.unstakeRequests(user1);
        assertApproxEqAbs(requestedAmount1, 100 * 1e18, 1);

        // --- Action 2: Advance time and make a second request ---
        vm.warp(block.timestamp + 1 days);
        uint256 sharesToUnstake2 = stakingManager.tokensToShares(50 * 1e18);
        vm.startPrank(user1);
        stakingManager.initiateUnstake(sharesToUnstake2);
        vm.stopPrank();

        // --- Assertions 2 ---
        (uint256 requestedAmount2, uint256 releaseTime2) = stakingManager.unstakeRequests(user1);

        // Amount should be cumulative
        assertApproxEqAbs(requestedAmount2, 150 * 1e18, 2, "Requested amount should be cumulative");

        // Cooldown timer should have reset from the *second* call
        assertTrue(releaseTime2 > releaseTime1, "New release time should be later than the first");
        assertApproxEqAbs(releaseTime2, block.timestamp + UNSTAKING_COOLDOWN, 1, "Release time should be reset");
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
