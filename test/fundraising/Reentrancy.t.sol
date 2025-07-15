// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ProjectBondingCurve} from "../../src/fundraising/ProjectBondingCurve.sol";
import {ProjectToken} from "../../src/fundraising/ProjectToken.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

// This is a malicious version of our ProjectToken.
// It overrides the internal `_update` function (which is called by `_burn`)
// to attempt a re-entrant call back into the bonding curve.
contract MaliciousProjectToken is ProjectToken {
    ProjectBondingCurve public curve;

    constructor(string memory name, string memory symbol, address initialOwner)
        ProjectToken(name, symbol, initialOwner)
    {}

    // Set the target for the re-entrant attack
    function setAttackTarget(address curveAddress) public {
        curve = ProjectBondingCurve(curveAddress);
    }

    // This is the hook for the attack. It gets called during a burn operation.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        // If this `_update` was triggered by a burn (to == address(0))
        // and we have a target, launch the re-entrant attack.
        if (to == address(0) && address(curve) != address(0)) {
            // This call should be reverted by the nonReentrant modifier.
            // Even though the attacker is not the owner, the re-entrancy check
            // happens before the ownership check.
            curve.withdrawCollateral();
        }
    }
}

contract ReentrancyTest is Test {
    // --- Constants ---
    uint256 internal constant SLOPE = 1;
    uint256 internal constant TEAM_ALLOCATION = 1000e18;
    uint256 internal constant VESTING_CLIFF = 30 days;
    uint256 internal constant VESTING_DURATION = 90 days;
    uint256 internal constant MAX_WITHDRAWAL_PERCENTAGE = 1500; // 15%
    uint256 internal constant WITHDRAWAL_FREQUENCY = 7 days;

    // --- Actors ---
    address public projectOwner;
    address public attacker;

    // --- Contracts ---
    ProjectBondingCurve public curve;
    MaliciousProjectToken public maliciousToken;
    MockERC20 public collateralToken;

    function setUp() public {
        projectOwner = makeAddr("projectOwner");
        attacker = makeAddr("attacker");
        collateralToken = new MockERC20("Mock USDC", "USDC", 6);

        // Deploy the implementation and create a proxy clone
        ProjectBondingCurve implementation = new ProjectBondingCurve();
        address curveAddress = Clones.clone(address(implementation));
        curve = ProjectBondingCurve(curveAddress);

        // Deploy our malicious token, with the test contract as the initial owner
        maliciousToken = new MaliciousProjectToken("Malicious", "EVIL", address(this));

        // Set the attack target on the token
        maliciousToken.setAttackTarget(address(curve));

        bytes memory strategyData = abi.encode(
            SLOPE, TEAM_ALLOCATION, VESTING_CLIFF, VESTING_DURATION, MAX_WITHDRAWAL_PERCENTAGE, WITHDRAWAL_FREQUENCY
        );

        // Transfer ownership of the malicious token to the curve contract so it can mint/burn
        maliciousToken.transferOwnership(address(curve));

        // Initialize the curve to use the malicious token
        curve.initialize(address(maliciousToken), address(collateralToken), projectOwner, strategyData);

        // Attacker buys some malicious tokens to be able to sell them later
        collateralToken.mint(attacker, 10_000_000 * 1e6);
        vm.startPrank(attacker);
        collateralToken.approve(address(curve), type(uint256).max);
        uint256 buyCost = curve.getBuyPrice(100e18);
        curve.buy(100e18, buyCost);
        vm.stopPrank();
    }

    function test_Fail_ReentrantSell() public {
        // --- Setup the scenario ---
        // 1. Warp time forward so a withdrawal would be possible (to make the attack vector realistic)
        vm.warp(block.timestamp + WITHDRAWAL_FREQUENCY + 1);

        // 2. To make a withdrawal possible, there must be collateral available for withdrawal.
        // We simulate another user buying tokens.
        address anotherBuyer = makeAddr("anotherBuyer");
        collateralToken.mint(anotherBuyer, 10_000_000 * 1e6);
        vm.startPrank(anotherBuyer);
        collateralToken.approve(address(curve), type(uint256).max);
        uint256 buyCost = curve.getBuyPrice(50e18);
        curve.buy(50e18, buyCost);
        vm.stopPrank();

        // --- Launch the attack ---
        // The attacker will try to sell their 100 tokens.
        // Inside the `burnFrom` call, our malicious token will try to re-enter
        // the `withdrawCollateral` function.
        vm.startPrank(attacker);

        // Attacker needs to approve the curve to spend their project tokens for the sell
        maliciousToken.approve(address(curve), 100e18);

        // We expect this to revert with the error from OpenZeppelin's ReentrancyGuard
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        curve.sell(100e18, 0); // minProceeds = 0 for simplicity

        vm.stopPrank();
    }
}
