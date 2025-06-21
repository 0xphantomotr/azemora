// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {QuestManager} from "../../src/achievements/QuestManager.sol";
import {IAchievementSBT, IReputationManager, IQuestVerifier} from "../../src/achievements/QuestManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// --- Mocks ---

contract MockAZE is IERC20 {
    mapping(address => uint256) public balanceOf;
    string public constant name = "Mock AZE";
    string public constant symbol = "mAZE";
    uint8 public constant decimals = 18;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function totalSupply() external pure returns (uint256) {
        return 1_000_000_000 * 10 ** 18;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockAchievementSBT is IAchievementSBT {
    mapping(address => uint256[]) public userAchievements;
    mapping(uint256 => address) public ownerOf;

    function mintAchievement(address user, uint256 achievementId) external {
        userAchievements[user].push(achievementId);
        ownerOf[achievementId] = user;
    }
}

contract MockReputationManager is IReputationManager {
    mapping(address => uint256) public reputation;

    function addReputation(address user, uint256 amount) external {
        reputation[user] += amount;
    }
}

contract MockQuestVerifier is IQuestVerifier {
    bool private _shouldSucceed;

    function setShouldSucceed(bool shouldSucceed) external {
        _shouldSucceed = shouldSucceed;
    }

    function verify(address) external view returns (bool) {
        return _shouldSucceed;
    }
}

// --- Tests ---

contract QuestManagerTest is Test {
    QuestManager internal questManager;
    MockAZE internal aze;
    MockAchievementSBT internal sbt;
    MockReputationManager internal rep;
    MockQuestVerifier internal verifier;

    address internal admin = makeAddr("admin");
    address internal user = makeAddr("user");

    uint256 public constant AZE_REWARD = 100 * 10 ** 18;
    uint256 public constant SBT_ID = 1;
    uint256 public constant REP_REWARD = 50;

    function setUp() public {
        // Deploy implementation
        QuestManager impl = new QuestManager();

        // Deploy proxy and initialize. The initializer grants admin roles to `address(this)`.
        bytes memory data = abi.encodeWithSelector(QuestManager.initialize.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        questManager = QuestManager(address(proxy));

        // Deploy mocks
        aze = new MockAZE();
        sbt = new MockAchievementSBT();
        rep = new MockReputationManager();
        verifier = new MockQuestVerifier();

        // Grant the designated admin account its role.
        questManager.grantRole(questManager.QUEST_ADMIN_ROLE(), admin);

        // Revoke the role from the test contract itself to keep the state clean and unambiguous.
        questManager.revokeRole(questManager.QUEST_ADMIN_ROLE(), address(this));

        // Fund QuestManager with AZE
        aze.mint(address(questManager), 1_000_000 * 10 ** 18);
    }

    // --- Admin Function Tests ---

    function test_CreateQuest() public {
        vm.startPrank(admin);
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.AZE,
            address(aze),
            AZE_REWARD,
            address(verifier),
            verifier.verify.selector,
            true
        );
        vm.stopPrank();

        QuestManager.Quest memory quest = questManager.getQuest(1);
        assertEq(quest.id, 1);
        assertEq(quest.rewardContract, address(aze));
        assertEq(quest.rewardIdOrAmount, AZE_REWARD);
        assertTrue(quest.isActive);
    }

    function test_Fail_CreateQuest_NotAdmin() public {
        // Read the role hash into a local variable BEFORE setting the prank.
        bytes32 questAdminRole = questManager.QUEST_ADMIN_ROLE();

        // Now, set the prank. It will apply to the next external call, which is createQuest.
        vm.prank(user);

        // Build the expected revert data using the local variable.
        bytes memory expectedRevertData = abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), user, questAdminRole
        );
        vm.expectRevert(expectedRevertData);

        // This is now the next external call, so the prank is correctly applied.
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.AZE,
            address(aze),
            AZE_REWARD,
            address(verifier),
            verifier.verify.selector,
            true
        );
    }

    function test_ToggleQuestStatus() public {
        // Create quest first
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.AZE,
            address(aze),
            AZE_REWARD,
            address(verifier),
            verifier.verify.selector,
            true
        );

        // Toggle off
        vm.prank(admin);
        questManager.toggleQuestStatus(1, false);
        QuestManager.Quest memory quest = questManager.getQuest(1);
        assertFalse(quest.isActive);

        // Toggle on
        vm.prank(admin);
        questManager.toggleQuestStatus(1, true);
        quest = questManager.getQuest(1);
        assertTrue(quest.isActive);
    }

    // --- Claim Reward Tests ---

    function test_ClaimReward_AZE() public {
        // 1. Admin creates quest
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.AZE,
            address(aze),
            AZE_REWARD,
            address(verifier),
            verifier.verify.selector,
            true
        );

        // 2. Verifier is set to succeed
        verifier.setShouldSucceed(true);

        // 3. User claims reward
        uint256 balanceBefore = aze.balanceOf(user);
        vm.prank(user);
        questManager.claimReward(1);
        uint256 balanceAfter = aze.balanceOf(user);

        assertEq(balanceAfter, balanceBefore + AZE_REWARD);
        assertTrue(questManager.questCompleted(1, user));
    }

    function test_ClaimReward_SBT() public {
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.SBT,
            address(sbt),
            SBT_ID,
            address(verifier),
            verifier.verify.selector,
            true
        );
        verifier.setShouldSucceed(true);

        vm.prank(user);
        questManager.claimReward(1);

        assertEq(sbt.ownerOf(SBT_ID), user);
        assertEq(sbt.userAchievements(user, 0), SBT_ID);
    }

    function test_ClaimReward_Reputation() public {
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.REPUTATION,
            address(rep),
            REP_REWARD,
            address(verifier),
            verifier.verify.selector,
            true
        );
        verifier.setShouldSucceed(true);

        uint256 repBefore = rep.reputation(user);
        vm.prank(user);
        questManager.claimReward(1);
        uint256 repAfter = rep.reputation(user);

        assertEq(repAfter, repBefore + REP_REWARD);
    }

    function test_Fail_ClaimReward_AlreadyCompleted() public {
        // Setup quest and claim once
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.AZE,
            address(aze),
            AZE_REWARD,
            address(verifier),
            verifier.verify.selector,
            true
        );
        verifier.setShouldSucceed(true);
        vm.prank(user);
        questManager.claimReward(1);

        // Try to claim again
        vm.prank(user);
        vm.expectRevert(QuestManager.QuestManager__QuestAlreadyCompleted.selector);
        questManager.claimReward(1);
    }

    function test_Fail_ClaimReward_VerificationFails() public {
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.AZE,
            address(aze),
            AZE_REWARD,
            address(verifier),
            verifier.verify.selector,
            true
        );

        // Set verifier to fail
        verifier.setShouldSucceed(false);

        vm.prank(user);
        vm.expectRevert(QuestManager.QuestManager__VerificationFailed.selector);
        questManager.claimReward(1);
    }
}
