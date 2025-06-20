// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {EntryPoint} from "@account-abstraction/core/EntryPoint.sol";
import {AzemoraSocialRecoveryWallet} from "../../src/account-abstraction/wallet/AzemoraSocialRecoveryWallet.sol";
import {AzemoraSocialRecoveryWalletFactory} from
    "../../src/account-abstraction/wallet/AzemoraSocialRecoveryWalletFactory.sol";

contract SocialRecoveryTest is Test {
    EntryPoint internal entryPoint;
    AzemoraSocialRecoveryWallet internal wallet;
    AzemoraSocialRecoveryWalletFactory internal factory;

    address internal owner;
    address internal newOwner;
    address[] internal guardians;
    uint256 internal guardianThreshold;

    function setUp() public virtual {
        entryPoint = new EntryPoint();
        factory = new AzemoraSocialRecoveryWalletFactory(entryPoint);

        owner = makeAddr("owner");
        newOwner = makeAddr("newOwner");

        guardians = new address[](3);
        guardians[0] = makeAddr("guardian1");
        guardians[1] = makeAddr("guardian2");
        guardians[2] = makeAddr("guardian3");

        guardianThreshold = 2;

        // The factory call must not be pranked as it's the deployer.
        // The initialization call within the factory is what sets the owner.
        address walletAddr = factory.createAccount(owner, guardians, guardianThreshold, 0);
        wallet = AzemoraSocialRecoveryWallet(payable(walletAddr));

        vm.deal(address(wallet), 1 ether);
    }

    // --- Test Setup ---
    function test_InitialState() public view {
        assertEq(wallet.owner(), owner, "Owner should be set correctly");
        assertEq(wallet.guardianThreshold(), guardianThreshold, "Threshold should be set");
        assertTrue(wallet.isGuardian(guardians[0]), "Guardian 1 should be a guardian");
        assertTrue(wallet.isGuardian(guardians[1]), "Guardian 2 should be a guardian");
        assertTrue(wallet.isGuardian(guardians[2]), "Guardian 3 should be a guardian");
        assertEq(wallet.getGuardians().length, 3, "Should have 3 guardians");
    }

    // --- Test Guardian Management ---
    function test_OwnerCanAddGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(owner);
        wallet.addGuardian(newGuardian);
        assertTrue(wallet.isGuardian(newGuardian));
        assertEq(wallet.getGuardians().length, 4);
    }

    function test_Fail_NonOwnerCannotAddGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(newGuardian); // Not the owner
        vm.expectRevert("caller is not the owner");
        wallet.addGuardian(newGuardian);
    }

    function test_OwnerCanRemoveGuardian() public {
        vm.prank(owner);
        wallet.removeGuardian(guardians[2]);
        assertFalse(wallet.isGuardian(guardians[2]));
        assertEq(wallet.getGuardians().length, 2);
    }

    function test_Fail_CannotRemoveGuardianBelowThreshold() public {
        vm.prank(owner);
        wallet.removeGuardian(guardians[2]); // Now 2 guardians, threshold is 2

        vm.prank(owner);
        vm.expectRevert("Cannot remove guardian below threshold");
        wallet.removeGuardian(guardians[1]);
    }

    function test_OwnerCanChangeThreshold() public {
        vm.prank(owner);
        wallet.setGuardianThreshold(3);
        assertEq(wallet.guardianThreshold(), 3);
    }

    // --- Test Recovery Happy Path ---
    function test_Recovery_HappyPath() public {
        // 1. Guardian 1 proposes recovery
        vm.prank(guardians[0]);
        wallet.proposeNewOwner(newOwner);
        assertTrue(wallet.recoveryIsActive());

        // 2. Guardian 2 supports recovery (meets threshold of 2)
        vm.prank(guardians[1]);
        wallet.supportRecovery();

        // 3. Fast-forward time past the timelock
        vm.warp(block.timestamp + wallet.RECOVERY_TIMELOCK() + 1);

        // 4. Anyone can execute recovery
        vm.prank(makeAddr("random_executor"));
        wallet.executeRecovery();

        // 5. Verify owner has changed
        assertEq(wallet.owner(), newOwner);
        assertFalse(wallet.recoveryIsActive());
    }

    // --- Test Recovery Failure Cases ---

    function test_Fail_ExecuteRecoveryBeforeThresholdMet() public {
        vm.prank(guardians[0]);
        wallet.proposeNewOwner(newOwner);

        vm.warp(block.timestamp + wallet.RECOVERY_TIMELOCK() + 1);

        vm.expectRevert("Insufficient approvals");
        wallet.executeRecovery();
    }

    function test_Fail_ExecuteRecoveryBeforeTimelock() public {
        vm.prank(guardians[0]);
        wallet.proposeNewOwner(newOwner);

        vm.prank(guardians[1]);
        wallet.supportRecovery();

        // Note: Not fast-forwarding time
        vm.expectRevert("Timelock not passed");
        wallet.executeRecovery();
    }

    function test_Fail_NonGuardianCannotPropose() public {
        vm.prank(makeAddr("not_a_guardian"));
        vm.expectRevert("caller is not a guardian");
        wallet.proposeNewOwner(newOwner);
    }

    function test_Fail_GuardianCannotSupportTwice() public {
        vm.prank(guardians[0]);
        wallet.proposeNewOwner(newOwner);

        vm.prank(guardians[0]); // Same guardian
        vm.expectRevert("Already supported");
        wallet.supportRecovery();
    }

    // --- Test Recovery Cancellation ---
    function test_OwnerCanCancelRecovery() public {
        // 1. Guardian 1 proposes
        vm.prank(guardians[0]);
        wallet.proposeNewOwner(newOwner);
        assertTrue(wallet.recoveryIsActive());

        // 2. Owner cancels
        vm.prank(owner);
        wallet.cancelRecovery();
        assertFalse(wallet.recoveryIsActive());

        // 3. Guardian 2 trying to support should fail
        vm.prank(guardians[1]);
        vm.expectRevert("No active recovery");
        wallet.supportRecovery();

        // 4. Execute should also fail
        vm.warp(block.timestamp + wallet.RECOVERY_TIMELOCK() + 1);
        vm.expectRevert("No active recovery");
        wallet.executeRecovery();
    }

    function test_Fail_CancelRecoveryWhenInactive() public {
        vm.prank(owner);
        vm.expectRevert("No active recovery");
        wallet.cancelRecovery();
    }
}
