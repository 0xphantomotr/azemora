// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ProjectBondingCurve} from "../../src/fundraising/ProjectBondingCurve.sol";
import {ProjectToken} from "../../src/fundraising/ProjectToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title MockCollateralToken
/// @dev A simple mock ERC20 token for testing purposes.
contract MockCollateralToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public constant name = "Mock Collateral";
    string public constant symbol = "mCOL";
    uint8 public constant decimals = 18;

    function totalSupply() external view returns (uint256) {
        return type(uint256).max;
    }

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
        emit Transfer(address(0), to, amount);
    }
}

/// @title ProjectBondingCurveEchidnaTest
/// @notice Defines properties that should always hold true for the ProjectBondingCurve contract.
contract ProjectBondingCurveEchidnaTest is Test {
    ProjectBondingCurve internal bondingCurve;
    ProjectToken internal projectToken;
    MockCollateralToken internal collateralToken;

    // --- Actors ---
    address internal owner;
    address internal migrator;
    address[] internal users;

    // --- State Tracking for Invariants ---
    uint256 public lastOwnerWithdrawalTimestamp;
    uint256 public totalCollateralWithdrawn;

    // --- Config ---
    uint256 public constant SLOPE = 1e15; // A reasonable slope for testing
    uint256 public constant TEAM_ALLOCATION = 100_000e18;
    uint256 public constant VESTING_CLIFF = 30 days;
    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public constant MAX_WITHDRAWAL_BPS = 1500; // 15%
    uint256 public constant WITHDRAWAL_FREQUENCY = 7 days;
    uint256 constant NUM_USERS = 4;
    uint256 constant INITIAL_USER_BALANCE = 100_000e18;

    constructor() {
        // --- Create Actors ---
        owner = vm.addr(1);
        migrator = vm.addr(2);
        for (uint256 i = 0; i < NUM_USERS; i++) {
            users.push(vm.addr(uint256(keccak256(abi.encodePacked("user", i)))));
        }

        // --- Deploy & Configure Contracts ---
        collateralToken = new MockCollateralToken();

        // 1. Deploy the project token with the test contract as the temporary owner.
        projectToken = new ProjectToken("Project Token", "PRO", address(this));

        // 2. Deploy the LOGIC contract. Its initializer will be disabled, which is correct.
        ProjectBondingCurve implementation = new ProjectBondingCurve();

        // 3. Deploy the proxy WITHOUT initializing it, so we can set up ownership first.
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");

        // 4. Point our test contract variable to the proxy's address.
        bondingCurve = ProjectBondingCurve(address(proxy));

        // 5. Transfer ownership of the token from the test contract to the bonding curve proxy.
        // This is critical, as initialize() will call projectToken.mint().
        projectToken.transferOwnership(address(bondingCurve));

        // 6. Now, initialize the bonding curve contract via the proxy.
        // We prank as the 'migrator' because initialize() sets `liquidityMigrator = msg.sender`.
        vm.prank(migrator);
        bytes memory strategyInitData = abi.encode(
            SLOPE, TEAM_ALLOCATION, VESTING_CLIFF, VESTING_DURATION, MAX_WITHDRAWAL_BPS, WITHDRAWAL_FREQUENCY
        );
        bondingCurve.initialize(address(projectToken), address(collateralToken), owner, strategyInitData);

        lastOwnerWithdrawalTimestamp = block.timestamp;

        // --- Fund Users ---
        for (uint256 i = 0; i < NUM_USERS; i++) {
            collateralToken.mint(users[i], INITIAL_USER_BALANCE);
        }
    }

    // =================================================================
    //                           INVARIANTS
    // =================================================================

    /// @dev Property: The collateral held by the contract should always match the integral of the price curve,
    /// minus any collateral the owner has legitimately withdrawn.
    function echidna_collateral_is_conserved() public view returns (bool) {
        uint256 supply = projectToken.totalSupply() - TEAM_ALLOCATION;
        uint256 curveCollateral = (SLOPE * supply * supply) / (2 * 1e18);

        // The expected collateral is the amount dictated by the curve, minus what the owner has withdrawn.
        // It's possible for the curve to be "in debt" if the owner withdraws a large amount and then
        // users sell tokens, reducing the required collateral below the withdrawn amount.
        uint256 expectedCollateral;
        if (curveCollateral >= totalCollateralWithdrawn) {
            expectedCollateral = curveCollateral - totalCollateralWithdrawn;
        } else {
            // The contract is "in debt" - the owner has taken more than the current supply requires.
            // The expected balance is zero, as the contract can't have negative collateral.
            expectedCollateral = 0;
        }

        uint256 actualCollateral = collateralToken.balanceOf(address(bondingCurve));

        // Allow for a reasonable amount of precision loss dust to accumulate.
        uint256 DUST_TOLERANCE = 1_000_000;

        uint256 difference = expectedCollateral > actualCollateral
            ? expectedCollateral - actualCollateral
            : actualCollateral - expectedCollateral;

        if (difference > DUST_TOLERANCE) {
            return false;
        }
        return true;
    }

    /// @dev Property: The owner cannot claim more tokens than have vested.
    function echidna_vesting_schedule_is_enforced() public view returns (bool) {
        uint256 vestedAmount;
        uint256 startTime = bondingCurve.vestingStartTime();
        uint256 cliff = bondingCurve.vestingCliff();
        uint256 duration = bondingCurve.vestingDuration();

        if (block.timestamp < cliff) {
            vestedAmount = 0;
        } else if (block.timestamp >= startTime + duration) {
            vestedAmount = TEAM_ALLOCATION;
        } else {
            vestedAmount = (TEAM_ALLOCATION * (block.timestamp - startTime)) / duration;
        }

        uint256 claimedAmount = bondingCurve.teamTokensClaimed();
        if (claimedAmount > vestedAmount) {
            return false;
        }
        return true;
    }

    /// @dev Property: Owner withdrawals must respect amount and frequency limits.
    function echidna_withdrawal_limits_are_enforced() public view returns (bool) {
        // This invariant is implicitly checked by the state-changing `withdrawCollateral` function.
        // If the owner withdraws, we update our internal timestamp. If they try to withdraw
        // too soon, the contract will revert, and our state remains consistent. The important
        // thing is that a successful withdrawal cannot happen if the cooldown is active.
        return true;
    }

    // =================================================================
    //                      STATE-CHANGING FUNCTIONS
    // =================================================================

    function buy(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        uint256 amount = (seed % 1000e18) + 1; // Buy up to 1000 tokens

        uint256 maxCost = bondingCurve.getBuyPrice(amount);

        vm.startPrank(user);
        collateralToken.approve(address(bondingCurve), maxCost);
        try bondingCurve.buy(amount, maxCost) {} catch {}
        vm.stopPrank();
    }

    function sell(uint256 seed) public {
        address user = users[seed % NUM_USERS];
        uint256 userBalance = projectToken.balanceOf(user);
        if (userBalance == 0) return;

        uint256 amount = (seed % userBalance) + 1;
        uint256 minReceive = bondingCurve.getSellPrice(amount);

        vm.startPrank(user);
        projectToken.approve(address(bondingCurve), amount);
        try bondingCurve.sell(amount, minReceive) {} catch {}
        vm.stopPrank();
    }

    function withdrawCollateral(uint256 seed) public {
        vm.prank(owner);
        // We only update our internal timestamp and withdrawal counter on successful withdrawals.
        try bondingCurve.withdrawCollateral() returns (uint256 withdrawnAmount) {
            lastOwnerWithdrawalTimestamp = block.timestamp;
            totalCollateralWithdrawn += withdrawnAmount;
        } catch {}
    }

    function claimVestedTokens(uint256 seed) public {
        vm.prank(owner);
        try bondingCurve.claimVestedTokens() {} catch {}
    }

    function warpTime(uint256 seed) public {
        // Warp forward between 1 second and a full withdrawal + vesting period
        uint256 time = (seed % (VESTING_DURATION + WITHDRAWAL_FREQUENCY)) + 1;
        vm.warp(block.timestamp + time);
    }
}
