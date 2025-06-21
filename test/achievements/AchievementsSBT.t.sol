// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/achievements/AchievementsSBT.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract AchievementsSBTTest is Test {
    AchievementsSBT internal sbt;
    address internal deployer;
    address internal user1;
    address internal user2;
    address internal minter;
    address internal pauser;

    uint256 internal constant ACHIEVEMENT_ID_1 = 1;
    uint256 internal constant ACHIEVEMENT_ID_2 = 2;
    string internal constant CONTRACT_URI = "ipfs://contract_metadata";
    string internal constant ACHIEVEMENT_URI_1 = "ipfs://achievement_1";
    string internal constant ACHIEVEMENT_URI_2 = "ipfs://achievement_2";

    event AchievementURIUpdated(uint256 indexed achievementId, string newURI);

    function setUp() public {
        deployer = makeAddr("deployer");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        minter = makeAddr("minter");
        pauser = makeAddr("pauser");

        vm.startPrank(deployer);
        AchievementsSBT sbtImplementation = new AchievementsSBT();
        ERC1967Proxy proxy = new ERC1967Proxy(address(sbtImplementation), "");
        sbt = AchievementsSBT(address(proxy));
        sbt.initialize(CONTRACT_URI);

        sbt.grantRole(sbt.MINTER_ROLE(), minter);
        sbt.grantRole(sbt.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        vm.prank(deployer);
        sbt.setAchievementURI(ACHIEVEMENT_ID_1, ACHIEVEMENT_URI_1);
    }

    // --- Test Initialization ---
    function test_initialization() public view {
        assertTrue(sbt.hasRole(sbt.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(sbt.hasRole(sbt.MINTER_ROLE(), deployer));
        assertTrue(sbt.hasRole(sbt.PAUSER_ROLE(), pauser));
        assertEq(sbt.contractURI(), CONTRACT_URI);
    }

    // --- Test Minting ---
    function test_minterCanMint() public {
        vm.prank(minter);
        sbt.mintAchievement(user1, ACHIEVEMENT_ID_1, 1);
        assertEq(sbt.balanceOf(user1, ACHIEVEMENT_ID_1), 1);
    }

    function test_revert_nonMinterCannotMint() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), sbt.MINTER_ROLE()
            )
        );
        sbt.mintAchievement(user1, ACHIEVEMENT_ID_1, 1);
    }

    // --- Test Burning/Revoking ---
    function test_adminCanRevoke() public {
        vm.prank(minter);
        sbt.mintAchievement(user1, ACHIEVEMENT_ID_1, 1);

        vm.prank(deployer);
        sbt.revokeAchievement(user1, ACHIEVEMENT_ID_1, 1);
        assertEq(sbt.balanceOf(user1, ACHIEVEMENT_ID_1), 0);
    }

    function test_revert_nonAdminCannotRevoke() public {
        vm.prank(minter);
        sbt.mintAchievement(user1, ACHIEVEMENT_ID_1, 1);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), sbt.DEFAULT_ADMIN_ROLE()
            )
        );
        sbt.revokeAchievement(user1, ACHIEVEMENT_ID_1, 1);
    }

    // --- Test Non-Transferability ---
    function test_revert_transferIsDisabled() public {
        vm.prank(minter);
        sbt.mintAchievement(user1, ACHIEVEMENT_ID_1, 1);

        vm.prank(user1);
        vm.expectRevert(AchievementsSBT__TransferDisabled.selector);
        sbt.safeTransferFrom(user1, user2, ACHIEVEMENT_ID_1, 1, "");
    }

    function test_revert_batchTransferIsDisabled() public {
        vm.prank(minter);
        sbt.mintAchievement(user1, ACHIEVEMENT_ID_1, 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = ACHIEVEMENT_ID_1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        vm.prank(user1);
        vm.expectRevert(AchievementsSBT__TransferDisabled.selector);
        sbt.safeBatchTransferFrom(user1, user2, ids, amounts, "");
    }

    // --- Test Metadata ---
    function test_uriReturnsCorrectURI() public view {
        assertEq(sbt.uri(ACHIEVEMENT_ID_1), ACHIEVEMENT_URI_1);
    }

    function test_revert_uriForUnsetAchievement() public {
        vm.expectRevert(AchievementsSBT__URINotSetForAchievement.selector);
        sbt.uri(ACHIEVEMENT_ID_2);
    }

    function test_adminCanSetAchievementURI() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit AchievementURIUpdated(ACHIEVEMENT_ID_2, ACHIEVEMENT_URI_2);
        sbt.setAchievementURI(ACHIEVEMENT_ID_2, ACHIEVEMENT_URI_2);
        assertEq(sbt.uri(ACHIEVEMENT_ID_2), ACHIEVEMENT_URI_2);
    }

    function test_revert_nonAdminCannotSetURI() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), sbt.DEFAULT_ADMIN_ROLE()
            )
        );
        sbt.setAchievementURI(ACHIEVEMENT_ID_2, ACHIEVEMENT_URI_2);
    }

    // --- Test Pausable ---
    function test_pausable() public {
        vm.prank(pauser);
        sbt.pause();

        vm.startPrank(minter);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sbt.mintAchievement(user1, ACHIEVEMENT_ID_1, 1);
        vm.stopPrank();

        vm.prank(pauser);
        sbt.unpause();

        vm.prank(minter);
        sbt.mintAchievement(user1, ACHIEVEMENT_ID_1, 1);
        assertEq(sbt.balanceOf(user1, ACHIEVEMENT_ID_1), 1);
    }

    // --- Test ERC-5192 ---
    function test_lockedIsAlwaysTrue() public view {
        assertTrue(sbt.locked(ACHIEVEMENT_ID_1));
        assertTrue(sbt.locked(9999)); // Should be true for any ID
    }
}
