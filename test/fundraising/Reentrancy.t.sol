// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ProjectBondingCurve} from "../../src/fundraising/ProjectBondingCurve.sol";
import {ProjectToken} from "../../src/fundraising/ProjectToken.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
            // This call should be reverted by the nonReentrant modifier on withdrawCollateral
            curve.withdrawCollateral();
        }
    }
}

contract ReentrancyTest is Test {
    // --- Actors ---
    address public owner = makeAddr("owner");
    address public investor = makeAddr("investor");

    // --- Contracts ---
    ProjectBondingCurve public curve;
    MaliciousProjectToken public maliciousToken;
    MockCollateral public collateral;

    function setUp() public {
        // --- Deploy contracts ---
        collateral = new MockCollateral();
        curve = new ProjectBondingCurve();

        // Deploy our malicious token, with the test contract as the initial owner
        maliciousToken = new MaliciousProjectToken("Malicious", "EVIL", address(this));

        // Set the attack target on the token
        maliciousToken.setAttackTarget(address(curve));

        // Transfer ownership of the malicious token to the curve contract
        maliciousToken.transferOwnership(address(curve));

        // Initialize the curve to use the malicious token
        curve.initialize(
            address(maliciousToken),
            address(collateral),
            owner, // Project owner
            1e9, // slope
            1000e18, // teamAllocation
            30 days, // cliff
            90 days, // duration
            1500, // maxWithdrawal
            7 days // frequency
        );
    }

    function test_Fail_ReentrantSell() public {
        // --- Setup the scenario ---
        // 1. Investor buys some tokens to populate the curve with collateral
        uint256 buyAmount = 100e18;
        uint256 buyCost = curve.getBuyPrice(buyAmount);
        collateral.mint(investor, buyCost);

        vm.startPrank(investor);
        collateral.approve(address(curve), buyCost);
        curve.buy(buyAmount, buyCost);
        vm.stopPrank();

        // 2. Warp time forward so the owner can withdraw
        vm.warp(block.timestamp + 8 days);

        // --- Launch the attack ---
        // The investor will try to sell their tokens.
        // Inside the `burnFrom` call, our malicious token will try to re-enter
        // the `withdrawCollateral` function.
        vm.startPrank(investor);
        maliciousToken.approve(address(curve), buyAmount);

        // We expect this to revert with the error from OpenZeppelin's ReentrancyGuard
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        curve.sell(buyAmount, 0); // minProceeds = 0 for simplicity

        vm.stopPrank();
    }
}
