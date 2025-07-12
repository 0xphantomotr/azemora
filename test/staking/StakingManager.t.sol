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
