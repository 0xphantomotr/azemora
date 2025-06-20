// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {AzemoraSocialRecoveryWallet} from "../../src/account-abstraction/wallet/AzemoraSocialRecoveryWallet.sol";
import {EntryPoint} from "@account-abstraction/core/EntryPoint.sol";

// --- The Handler Contract ---
// This contract is what Foundry's invariant tester will actually call.
// Its purpose is to translate fuzzed inputs into valid calls on our real wallet.
contract Handler is Test {
    AzemoraSocialRecoveryWallet internal wallet;
    address[] internal actors; // A pool of addresses to act as guardians/owners
    address[] internal currentGuardians;

    constructor(AzemoraSocialRecoveryWallet _wallet) {
        wallet = _wallet;
        // Create a pool of 5 addresses to use in the test
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        actors.push(makeAddr("actor4"));
        actors.push(makeAddr("actor5"));
    }

    // --- State-Changing Functions for Fuzzer ---

    // Helper to update our local list of guardians
    function _updateGuardians() internal {
        currentGuardians = wallet.getGuardians();
    }

    function addGuardian(uint256 actorIndex) public {
        _updateGuardians();
        address actor = actors[actorIndex % actors.length];
        address owner = wallet.owner();
        vm.prank(owner);
        // We use a try/catch block because we expect some calls to fail (e.g., adding an existing guardian).
        // This is normal in invariant testing; we want to test what happens even after reverts.
        try wallet.addGuardian(actor) {} catch {}
    }

    function removeGuardian(uint256 actorIndex) public {
        _updateGuardians();
        if (currentGuardians.length == 0) return; // Cannot remove from empty set
        address guardianToRemove = currentGuardians[actorIndex % currentGuardians.length];
        address owner = wallet.owner();
        vm.prank(owner);
        try wallet.removeGuardian(guardianToRemove) {} catch {}
    }

    function proposeNewOwner(uint256 proposerIndex, uint256 newOwnerIndex) public {
        _updateGuardians();
        if (currentGuardians.length == 0) return; // Cannot propose without guardians
        address proposer = currentGuardians[proposerIndex % currentGuardians.length];
        address newOwner = actors[newOwnerIndex % actors.length];
        vm.prank(proposer);
        try wallet.proposeNewOwner(newOwner) {} catch {}
    }

    function supportRecovery(uint256 supporterIndex) public {
        _updateGuardians();
        if (currentGuardians.length == 0) return; // Cannot support without guardians
        address supporter = currentGuardians[supporterIndex % currentGuardians.length];
        vm.prank(supporter);
        try wallet.supportRecovery() {} catch {}
    }

    function executeRecovery() public {
        // Anyone can call executeRecovery
        address executor = actors[block.timestamp % actors.length];
        vm.prank(executor);
        try wallet.executeRecovery() {} catch {}
    }

    function cancelRecovery() public {
        address owner = wallet.owner();
        vm.prank(owner);
        try wallet.cancelRecovery() {} catch {}
    }
}

// --- The Invariant Test Suite ---
contract SocialRecoveryInvariantTest is Test {
    AzemoraSocialRecoveryWallet internal wallet;
    Handler internal handler;

    // We store the owner before each call to check for valid changes.
    address internal ownerBefore;

    function setUp() public {
        // Deploy a wallet with 3 guardians and a threshold of 2.
        address initialOwner = makeAddr("initialOwner");
        address[] memory initialGuardians = new address[](3);
        initialGuardians[0] = makeAddr("initialGuardian1");
        initialGuardians[1] = makeAddr("initialGuardian2");
        initialGuardians[2] = makeAddr("initialGuardian3");

        wallet = new AzemoraSocialRecoveryWallet();
        wallet.initialize(new EntryPoint(), initialOwner, initialGuardians, 2);

        handler = new Handler(wallet);

        // Tell Foundry to target the handler contract for its random calls.
        targetContract(address(handler));
    }

    // --- The Invariant Rules ---

    // This function runs before every call in the sequence.
    function _beforeCall() internal {
        ownerBefore = wallet.owner();
    }

    // Invariant 1: The number of guardians must never fall below the threshold.
    function invariant_guardianCountNeverBelowThreshold() public view {
        assertTrue(wallet.getGuardians().length >= wallet.guardianThreshold());
    }

    // Invariant 2: If a recovery process is active, the current owner must
    // not be the same as the proposed new owner. The change can only happen
    // after a successful `executeRecovery`.
    function invariant_ownerNotChangedDuringActiveRecovery() public view {
        if (wallet.recoveryIsActive()) {
            (address newOwner, uint256 approvalCount, uint256 proposedAt) = wallet.activeRecovery();
            assertFalse(wallet.owner() == newOwner, "Owner changed before recovery was executed");
        }
    }
}
