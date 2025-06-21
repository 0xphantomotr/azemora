// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/achievements/AchievementsSBT.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Handler for AchievementsSBT fuzzing
/// @dev This contract is called by the fuzzer. It translates random data into
/// function calls on the AchievementsSBT contract, simulating user behavior.
contract Handler is Test {
    AchievementsSBT internal sbt;

    // --- State for tracking ---
    address[] public users;
    uint256[] public achievementIds;

    constructor(AchievementsSBT _sbt) {
        sbt = _sbt;

        // Just populate the arrays. Role granting will happen outside.
        users.push(makeAddr("user0"));
        users.push(makeAddr("user1"));
        users.push(makeAddr("minter"));
        users.push(makeAddr("admin"));

        achievementIds.push(1);
        achievementIds.push(2);
    }

    // --- Fuzzer entry points ---

    function mintAchievement(address to, uint256 achievementId, uint256 amount) public {
        to = _pickUser(uint256(uint160(to)));
        achievementId = _pickAchievementId(achievementId);
        amount = bound(amount, 1, 5);

        vm.prank(users[2]); // prank as minter
        sbt.mintAchievement(to, achievementId, amount);
    }

    function revokeAchievement(address from, uint256 achievementId, uint256 amount) public {
        from = _pickUser(uint256(uint160(from)));
        achievementId = _pickAchievementId(achievementId);
        amount = bound(amount, 1, 5);

        vm.prank(users[3]); // prank as admin
        sbt.revokeAchievement(from, achievementId, amount);
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount) public {
        from = _pickUser(uint256(uint160(from)));
        to = _pickUser(uint256(uint160(to)));
        id = _pickAchievementId(id);

        if (from == to) return;

        vm.prank(from);
        // This call is expected to always revert due to the soulbound nature.
        // The invariant test will fail if a transfer somehow succeeds.
        vm.expectRevert(AchievementsSBT__TransferDisabled.selector);
        sbt.safeTransferFrom(from, to, id, amount, "");
    }

    // --- Helper functions to select random-but-valid inputs ---

    function _pickUser(uint256 randomNumber) internal view returns (address) {
        return users[randomNumber % users.length];
    }

    function _pickAchievementId(uint256 randomNumber) internal view returns (uint256) {
        return achievementIds[randomNumber % achievementIds.length];
    }

    // --- View functions to expose array lengths ---

    function getUsersCount() public view returns (uint256) {
        return users.length;
    }

    function getAchievementIdsCount() public view returns (uint256) {
        return achievementIds.length;
    }
}

contract AchievementsSBTInvariantTest is Test {
    AchievementsSBT internal sbt;
    Handler internal handler;

    // State for tracking balances between fuzzer runs
    mapping(address => mapping(uint256 => uint256)) public balances;

    function setUp() public {
        // Deploy and initialize the contract. `this` contract becomes the admin.
        AchievementsSBT sbtImplementation = new AchievementsSBT();
        ERC1967Proxy proxy = new ERC1967Proxy(address(sbtImplementation), "");
        sbt = AchievementsSBT(address(proxy));
        sbt.initialize("ipfs://contract_uri");

        // Create the handler
        handler = new Handler(sbt);

        // As the admin, grant roles to the handler's users
        sbt.grantRole(sbt.MINTER_ROLE(), handler.users(2)); // minter
        sbt.grantRole(sbt.DEFAULT_ADMIN_ROLE(), handler.users(3)); // admin

        // As the admin, set the achievement URIs
        for (uint256 i = 0; i < handler.getAchievementIdsCount(); i++) {
            sbt.setAchievementURI(handler.achievementIds(i), "uri");
        }

        // Setup the handler and target it for fuzzing
        targetContract(address(handler));

        // Take an initial snapshot of all balances
        _updateBalances();
    }

    /**
     * INVARIANT: A token can never be transferred between two non-zero addresses.
     *
     * This stateful invariant runs after every call the fuzzer makes to the Handler.
     * It checks that if any user's balance decreased, no other user's balance increased
     * in the same step, which would signify an illegal transfer.
     */
    function invariant_nonTransferable() public {
        uint256 userCount = handler.getUsersCount();
        uint256 achievementCount = handler.getAchievementIdsCount();

        // Check if any transfer happened
        for (uint256 i = 0; i < userCount; i++) {
            for (uint256 j = 0; j < userCount; j++) {
                if (i == j) continue; // Don't compare a user to themselves

                address userA = handler.users(i);
                address userB = handler.users(j);

                for (uint256 k = 0; k < achievementCount; k++) {
                    uint256 achievementId = handler.achievementIds(k);

                    uint256 oldBalanceA = balances[userA][achievementId];
                    uint256 newBalanceA = sbt.balanceOf(userA, achievementId);

                    if (newBalanceA < oldBalanceA) {
                        uint256 oldBalanceB = balances[userB][achievementId];
                        uint256 newBalanceB = sbt.balanceOf(userB, achievementId);
                        assertFalse(
                            newBalanceB > oldBalanceB,
                            "Illegal Transfer Occurred: User A's balance decreased while User B's increased."
                        );
                    }
                }
            }
        }

        // After checking, update the stored balances for the next run.
        _updateBalances();
    }

    /**
     * INVARIANT: The total supply of an achievement must equal the sum of all individual balances.
     */
    function invariant_totalSupplyIntegrity() public {
        uint256 achievementCount = handler.getAchievementIdsCount();
        uint256 userCount = handler.getUsersCount();

        for (uint256 i = 0; i < achievementCount; i++) {
            uint256 achievementId = handler.achievementIds(i);
            uint256 totalSupply = sbt.totalSupply(achievementId);

            uint256 sumOfBalances = 0;
            for (uint256 j = 0; j < userCount; j++) {
                sumOfBalances += sbt.balanceOf(handler.users(j), achievementId);
            }

            assertEq(totalSupply, sumOfBalances, "Total supply does not match the sum of individual balances.");
        }
    }

    function _updateBalances() internal {
        uint256 userCount = handler.getUsersCount();
        uint256 achievementCount = handler.getAchievementIdsCount();
        for (uint256 i = 0; i < userCount; i++) {
            for (uint256 j = 0; j < achievementCount; j++) {
                address user = handler.users(i);
                uint256 id = handler.achievementIds(j);
                balances[user][id] = sbt.balanceOf(user, id);
            }
        }
    }
}
