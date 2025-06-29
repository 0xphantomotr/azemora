// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReputationManager} from "../../src/achievements/ReputationManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ReputationManagerTest is Test {
    // --- Test setup ---
    ReputationManager internal reputationManager;

    // --- Roles ---
    bytes32 internal constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");
    bytes32 internal constant REPUTATION_SLASHER_ROLE = keccak256("REPUTATION_SLASHER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // --- Users ---
    address internal admin;
    address internal updater; // Represents the QuestManager
    address internal slasher; // Represents the VerifierManager
    address internal user;
    address internal randomAddress;

    function setUp() public {
        admin = makeAddr("admin");
        updater = makeAddr("updater");
        slasher = makeAddr("slasher");
        user = makeAddr("user");
        randomAddress = makeAddr("randomAddress");

        vm.startPrank(admin);

        // Deploy the implementation contract
        ReputationManager implementation = new ReputationManager();

        // Prepare the initialization data with BOTH required arguments
        bytes memory initData = abi.encodeWithSelector(ReputationManager.initialize.selector, updater, slasher);

        // Deploy the proxy and initialize it, then cast it to the ReputationManager type
        reputationManager = ReputationManager(address(new ERC1967Proxy(address(implementation), initData)));

        vm.stopPrank();
    }

    // --- Test Initialization ---

    function test_initialize_setsRolesCorrectly() public view {
        assertTrue(reputationManager.hasRole(DEFAULT_ADMIN_ROLE, admin), "Admin role not set");
        assertTrue(reputationManager.hasRole(REPUTATION_UPDATER_ROLE, updater), "Updater role not set");
        assertTrue(reputationManager.hasRole(REPUTATION_SLASHER_ROLE, slasher), "Slasher role not set");
    }

    // --- Test addReputation ---

    function test_addReputation_succeeds_whenCalledByUpdater() public {
        uint256 initialReputation = reputationManager.getReputation(user);
        assertEq(initialReputation, 0, "Initial reputation should be 0");

        uint256 amountToAdd = 100;
        vm.prank(updater);
        reputationManager.addReputation(user, amountToAdd);

        uint256 finalReputation = reputationManager.getReputation(user);
        assertEq(finalReputation, amountToAdd, "Reputation not added correctly");
    }

    function test_addReputation_reverts_whenCalledByNonUpdater() public {
        vm.startPrank(randomAddress);
        bytes memory expectedRevert = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomAddress, REPUTATION_UPDATER_ROLE
        );
        vm.expectRevert(expectedRevert);
        reputationManager.addReputation(user, 100);
        vm.stopPrank();
    }

    function test_addReputation_emitsEvent() public {
        uint256 amount = 50;
        vm.prank(updater);
        vm.expectEmit(true, true, true, true);
        emit ReputationManager.ReputationAdded(user, updater, amount, amount);
        reputationManager.addReputation(user, amount);
    }

    function test_addReputation_accumulatesScore() public {
        vm.prank(updater);
        reputationManager.addReputation(user, 100);

        vm.prank(updater);
        reputationManager.addReputation(user, 50);

        uint256 finalReputation = reputationManager.getReputation(user);
        assertEq(finalReputation, 150, "Reputation did not accumulate correctly");
    }

    // --- Test slashReputation ---

    function test_slashReputation_succeeds_whenCalledBySlasher() public {
        // First, add some reputation
        vm.prank(updater);
        reputationManager.addReputation(user, 100);

        uint256 amountToSlash = 30;
        vm.prank(slasher);
        reputationManager.slashReputation(user, amountToSlash);

        uint256 finalReputation = reputationManager.getReputation(user);
        assertEq(finalReputation, 70, "Reputation not slashed correctly");
    }

    function test_slashReputation_reverts_whenCalledByNonSlasher() public {
        vm.prank(updater);
        reputationManager.addReputation(user, 100);

        vm.startPrank(randomAddress);
        bytes memory expectedRevert = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomAddress, REPUTATION_SLASHER_ROLE
        );
        vm.expectRevert(expectedRevert);
        reputationManager.slashReputation(user, 50);
        vm.stopPrank();
    }

    function test_slashReputation_emitsEvent() public {
        vm.prank(updater);
        reputationManager.addReputation(user, 100);

        uint256 amountToSlash = 40;
        vm.prank(slasher);
        vm.expectEmit(true, true, true, true);
        emit ReputationManager.ReputationSlashed(user, slasher, amountToSlash, 60);
        reputationManager.slashReputation(user, amountToSlash);
    }

    function test_slashReputation_reverts_ifAmountExceedsBalance() public {
        vm.prank(updater);
        reputationManager.addReputation(user, 50);

        vm.prank(slasher);
        vm.expectRevert(ReputationManager.ReputationManager__ReputationCannotGoNegative.selector);
        reputationManager.slashReputation(user, 51);
    }

    // --- Test Role Management ---

    function test_admin_canGrantUpdaterRole() public {
        vm.prank(admin);
        reputationManager.grantRole(REPUTATION_UPDATER_ROLE, randomAddress);
        assertTrue(reputationManager.hasRole(REPUTATION_UPDATER_ROLE, randomAddress), "New updater role not granted");
    }

    function test_nonAdmin_cannotGrantUpdaterRole() public {
        vm.prank(randomAddress);
        bytes memory expectedRevert = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomAddress, DEFAULT_ADMIN_ROLE
        );
        vm.expectRevert(expectedRevert);
        reputationManager.grantRole(REPUTATION_UPDATER_ROLE, user);
    }

    // --- Test Upgradeability ---

    function test_authorizeUpgrade_reverts_whenCalledByNonAdmin() public {
        address newImplementation = address(new ReputationManager());
        vm.prank(randomAddress);
        bytes memory expectedRevert = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", randomAddress, DEFAULT_ADMIN_ROLE
        );
        vm.expectRevert(expectedRevert);
        reputationManager.upgradeToAndCall(newImplementation, "");
    }
}
