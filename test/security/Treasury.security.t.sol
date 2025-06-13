// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/governance/Treasury.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/*
 * @title MaliciousOwner
 * @notice A contract designed to perform a re-entrancy attack on the Treasury
 *         by being the Treasury's owner.
 * @dev Its `receive` function is triggered when it gets ETH from the Treasury.
 *      Because it is the owner, its re-entrant call to `withdrawETH` passes
 *      the `onlyOwner` check, allowing it to drain the contract.
 */
contract MaliciousOwner is Test {
    Treasury public treasury;
    uint256 public constant ATTACK_AMOUNT = 1 ether;

    /// @notice The entry point for the attack. It initiates the first withdrawal to itself.
    function attack() external {
        treasury.withdrawETH(address(this), ATTACK_AMOUNT);
    }

    /// @notice The re-entrancy hook.
    receive() external payable {
        // As long as the treasury has funds, keep withdrawing.
        if (address(treasury).balance > 0) {
            // Re-entrant call! This succeeds because this contract is the owner.
            treasury.withdrawETH(address(this), ATTACK_AMOUNT);
        }
    }

    // Helper to allow this contract to deploy and own the Treasury for the test.
    function deployAndownTreasury() public {
        Treasury treasuryImpl = new Treasury();
        treasury = Treasury(
            payable(
                address(
                    new ERC1967Proxy(
                        address(treasuryImpl),
                        // Initialize the Treasury with THIS contract as the owner
                        abi.encodeCall(Treasury.initialize, (address(this)))
                    )
                )
            )
        );
    }
}

/*
 * @title TreasurySecurityTest
 * @notice A test suite for security vulnerabilities in the Treasury.
 */
contract TreasurySecurityTest is Test {
    MaliciousOwner attacker;
    Treasury treasury;

    function setUp() public {
        // Deploy the attacker contract, which in turn deploys and owns the Treasury.
        attacker = new MaliciousOwner();
        attacker.deployAndownTreasury();
        treasury = attacker.treasury();

        // Fund the treasury with 10 ETH for the attack.
        vm.deal(address(treasury), 10 ether);
    }

    function test_revert_reentrancyOnWithdrawETH() public {
        // --- Pre-Attack State ---
        assertEq(address(treasury).balance, 10 ether);
        assertEq(address(attacker).balance, 0);

        // --- Execute the Attack ---
        // We expect the re-entrant call to fail, causing the `success` flag
        // in the original `withdrawETH` call to be false, triggering the
        // "ETH transfer failed" revert. This proves the guard worked as intended.
        vm.expectRevert(bytes("ETH transfer failed"));
        attacker.attack();

        // --- Post-Attack State Verification ---
        // The attacker should have received the FIRST payment, but the re-entrant
        // calls should have failed, reverting the entire transaction.
        // Therefore, the state should be exactly as it was before the attack.
        console.log("Attacker Balance After Attack:", address(attacker).balance);
        console.log("Treasury Balance After Attack:", address(treasury).balance);

        assertEq(address(attacker).balance, 0, "Attacker balance should be 0 because transaction reverted");
        assertEq(address(treasury).balance, 10 ether, "Treasury balance should be unchanged");
    }
}
