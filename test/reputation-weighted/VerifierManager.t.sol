// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    VerifierManager,
    VerifierManager__NotEnoughReputation,
    VerifierManager__NotEnoughStake,
    VerifierManager__AlreadyRegistered,
    VerifierManager__NotRegistered,
    VerifierManager__UnstakePeriodNotOver,
    VerifierManager__StillStaked
} from "../../src/reputation-weighted/VerifierManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockReputationManager} from "../mocks/MockReputationManager.sol";

contract VerifierManagerTest is Test {
    // --- Constants ---
    uint256 internal constant INITIAL_MINT_AMOUNT = 1_000_000 * 1e18;
    uint256 internal constant MIN_STAKE_AMOUNT = 100 * 1e18;
    uint256 internal constant MIN_REPUTATION = 50;
    uint256 internal constant UNSTAKE_LOCK_PERIOD = 7 days;
    bytes32 internal constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // --- State ---
    VerifierManager internal verifierManager;
    MockERC20 internal stakingToken;
    MockReputationManager internal reputationManager;

    // --- Users ---
    address internal admin;
    address internal slasher;
    address internal treasury;
    address internal userWithReputation;
    address internal userWithoutReputation;
    address internal userWithoutStake;
    address internal randomAddress;

    function setUp() public {
        admin = makeAddr("admin");
        slasher = makeAddr("slasher");
        treasury = makeAddr("treasury");
        userWithReputation = makeAddr("userWithReputation");
        userWithoutReputation = makeAddr("userWithoutReputation");
        userWithoutStake = makeAddr("userWithoutStake");
        randomAddress = makeAddr("randomAddress");

        // Deploy mocks
        stakingToken = new MockERC20("Azemora Token", "AZT", 18);
        reputationManager = new MockReputationManager();

        // Deploy implementation and proxy
        vm.startPrank(admin);
        VerifierManager implementation = new VerifierManager();
        bytes memory initData = abi.encodeWithSelector(
            VerifierManager.initialize.selector,
            admin,
            slasher,
            treasury,
            address(stakingToken),
            address(reputationManager),
            MIN_STAKE_AMOUNT,
            MIN_REPUTATION,
            UNSTAKE_LOCK_PERIOD
        );
        verifierManager = VerifierManager(address(new ERC1967Proxy(address(implementation), initData)));
        verifierManager.grantRole(verifierManager.SLASHER_ROLE(), slasher);
        vm.stopPrank();

        // Setup user states
        stakingToken.mint(userWithReputation, INITIAL_MINT_AMOUNT);
        reputationManager.setReputation(userWithReputation, MIN_REPUTATION + 10);

        reputationManager.setReputation(userWithoutReputation, MIN_REPUTATION - 10);
        stakingToken.mint(userWithoutReputation, INITIAL_MINT_AMOUNT);

        reputationManager.setReputation(userWithoutStake, MIN_REPUTATION + 10);
    }

    // --- Test Initialization ---

    function test_initialize_setsCorrectState() public {
        assertTrue(verifierManager.hasRole(DEFAULT_ADMIN_ROLE, admin), "Admin role not set");
        assertTrue(verifierManager.hasRole(SLASHER_ROLE, slasher), "Slasher role not set");
        assertEq(verifierManager.treasury(), treasury, "Treasury not set");
        assertEq(address(verifierManager.stakingToken()), address(stakingToken), "Staking token not set");
        assertEq(address(verifierManager.reputationManager()), address(reputationManager), "Reputation manager not set");
        assertEq(verifierManager.minStakeAmount(), MIN_STAKE_AMOUNT, "Min stake not set");
        assertEq(verifierManager.minReputation(), MIN_REPUTATION, "Min reputation not set");
        assertEq(verifierManager.unstakeLockPeriod(), UNSTAKE_LOCK_PERIOD, "Unstake period not set");
    }

    // --- Test Registration ---

    function test_register_succeeds() public {
        vm.startPrank(userWithReputation);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        assertTrue(verifierManager.isVerifier(userWithReputation), "User should be verifier");
        assertEq(verifierManager.getVerifierStake(userWithReputation), MIN_STAKE_AMOUNT, "Stake not recorded");
        assertEq(stakingToken.balanceOf(address(verifierManager)), MIN_STAKE_AMOUNT, "Contract did not receive stake");
    }

    function test_register_reverts_ifNotEnoughReputation() public {
        vm.startPrank(userWithoutReputation);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        vm.expectRevert(VerifierManager__NotEnoughReputation.selector);
        verifierManager.register();
        vm.stopPrank();
    }

    function test_register_reverts_ifNotEnoughStake() public {
        vm.startPrank(userWithoutStake);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        vm.expectRevert(VerifierManager__NotEnoughStake.selector);
        verifierManager.register();
        vm.stopPrank();
    }

    function test_register_reverts_ifAlreadyRegistered() public {
        vm.startPrank(userWithReputation);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.expectRevert(VerifierManager__AlreadyRegistered.selector);
        verifierManager.register();
        vm.stopPrank();
    }

    // --- Test Unstaking ---

    function test_fullUnstakeCycle_succeeds() public {
        // 1. Register
        vm.startPrank(userWithReputation);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();

        // 2. Initiate Unstake
        verifierManager.initiateUnstake();
        assertFalse(verifierManager.isVerifier(userWithReputation), "User should be inactive");
        (,, uint256 unstakeAvailableAt,) = verifierManager.verifiers(userWithReputation);
        assertEq(unstakeAvailableAt, block.timestamp + UNSTAKE_LOCK_PERIOD);

        // 3. Wait for lock period
        vm.warp(block.timestamp + UNSTAKE_LOCK_PERIOD + 1);

        // 4. Finalize Unstake
        uint256 initialBalance = stakingToken.balanceOf(userWithReputation);
        verifierManager.unstake();
        uint256 finalBalance = stakingToken.balanceOf(userWithReputation);

        assertEq(finalBalance, initialBalance + MIN_STAKE_AMOUNT, "Stake not returned");
        assertEq(verifierManager.getVerifierStake(userWithReputation), 0, "Stake should be zeroed");
        vm.stopPrank();
    }

    function test_unstake_reverts_ifNotInitiated() public {
        vm.startPrank(userWithReputation);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.expectRevert(VerifierManager__StillStaked.selector);
        verifierManager.unstake();
        vm.stopPrank();
    }

    function test_unstake_reverts_ifLockPeriodNotOver() public {
        vm.startPrank(userWithReputation);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        verifierManager.initiateUnstake();

        vm.warp(block.timestamp + UNSTAKE_LOCK_PERIOD - 10);

        vm.expectRevert(VerifierManager__UnstakePeriodNotOver.selector);
        verifierManager.unstake();
        vm.stopPrank();
    }

    // --- Test Slashing ---

    function test_slash_succeeds() public {
        // Register user
        vm.startPrank(userWithReputation);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        uint256 reputationBefore = reputationManager.getReputation(userWithReputation);

        vm.startPrank(slasher);
        // Expect reputation slash call
        vm.expectCall(
            address(reputationManager),
            abi.encodeWithSelector(reputationManager.slashReputation.selector, userWithReputation, reputationBefore)
        );
        verifierManager.slash(userWithReputation);
        vm.stopPrank();

        assertEq(verifierManager.getVerifierStake(userWithReputation), 0, "Stake not fully slashed");
        assertEq(stakingToken.balanceOf(treasury), MIN_STAKE_AMOUNT, "Treasury did not receive slashed stake");
        assertFalse(verifierManager.isVerifier(userWithReputation), "Verifier should be deactivated after slash");
    }

    function test_slash_reverts_ifNotSlasher() public {
        vm.startPrank(userWithReputation);
        stakingToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(randomAddress);
        bytes memory expectedRevert = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomAddress, verifierManager.SLASHER_ROLE()
        );
        vm.expectRevert(expectedRevert);
        verifierManager.slash(userWithReputation);
        vm.stopPrank();
    }

    // --- Test Admin Functions ---

    function test_adminFunctions_revert_ifNotAdmin() public {
        vm.startPrank(randomAddress);
        bytes memory expectedRevert = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomAddress, DEFAULT_ADMIN_ROLE
        );
        vm.expectRevert(expectedRevert);
        verifierManager.setMinStake(1);

        vm.expectRevert(expectedRevert);
        verifierManager.setMinReputation(1);
        vm.stopPrank();
    }
}
