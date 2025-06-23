// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {QuestManager} from "../../src/achievements/QuestManager.sol";
import {IAchievementSBT, IQuestVerifier} from "../../src/achievements/QuestManager.sol";
import {ReputationManager} from "../../src/achievements/ReputationManager.sol";
import {TokenBalanceVerifier} from "../../src/achievements/verifiers/TokenBalanceVerifier.sol";
import {NftHolderVerifier} from "../../src/achievements/verifiers/NftHolderVerifier.sol";
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
    mapping(address => mapping(uint256 => uint256)) public userAchievements;

    function mintAchievement(address user, uint256 achievementId) external {
        userAchievements[user][achievementId]++;
    }
}

contract MockNFT {
    mapping(address => uint256) public balanceOf;

    function mint(address to) external {
        balanceOf[to]++;
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
    ReputationManager internal reputationManager;
    TokenBalanceVerifier internal tokenVerifier;
    NftHolderVerifier internal nftVerifier;
    MockNFT internal nft;

    address internal admin = makeAddr("admin");
    address internal user = makeAddr("user");

    uint256 public constant AZE_REWARD = 100 * 10 ** 18;
    uint256 public constant SBT_ID = 1;
    uint256 public constant REP_REWARD = 50;

    function setUp() public virtual {
        // Deploy QuestManager (implementation and proxy)
        QuestManager impl = new QuestManager();
        bytes memory data = abi.encodeWithSelector(QuestManager.initialize.selector);
        questManager = QuestManager(address(new ERC1967Proxy(address(impl), data)));

        // Deploy ReputationManager (implementation and proxy)
        ReputationManager repImpl = new ReputationManager();
        // Initialize with QuestManager as the initial updater and a null slasher
        bytes memory repData =
            abi.encodeWithSelector(ReputationManager.initialize.selector, address(questManager), address(0));
        reputationManager = ReputationManager(address(new ERC1967Proxy(address(repImpl), repData)));

        // Deploy mocks and verifiers
        aze = new MockAZE();
        sbt = new MockAchievementSBT();
        nft = new MockNFT();
        tokenVerifier = new TokenBalanceVerifier(address(aze), AZE_REWARD, admin);
        nftVerifier = new NftHolderVerifier(address(nft), admin);

        // Grant admin roles from deployer (this) to the designated admin
        questManager.grantRole(questManager.DEFAULT_ADMIN_ROLE(), admin);
        reputationManager.grantRole(reputationManager.DEFAULT_ADMIN_ROLE(), admin);

        // New admin takes over role management
        vm.startPrank(admin);
        questManager.grantRole(questManager.QUEST_ADMIN_ROLE(), admin);
        questManager.revokeRole(questManager.DEFAULT_ADMIN_ROLE(), address(this));
        questManager.revokeRole(questManager.QUEST_ADMIN_ROLE(), address(this));
        reputationManager.revokeRole(reputationManager.DEFAULT_ADMIN_ROLE(), address(this));
        vm.stopPrank();

        // Fund QuestManager with AZE for rewards
        aze.mint(address(questManager), 1_000_000 * 10 ** 18);
    }

    // --- Admin Function Tests ---

    function test_CreateQuest() public {
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://test",
            QuestManager.RewardType.AZE,
            address(aze),
            AZE_REWARD,
            address(tokenVerifier),
            tokenVerifier.verify.selector,
            true
        );
        vm.stopPrank();

        QuestManager.Quest memory quest = questManager.getQuest(1);
        assertEq(quest.id, 1);
        assertEq(quest.rewardContract, address(aze));
        assertTrue(quest.isActive);
    }

    // --- Claim Reward Tests ---

    function test_ClaimReward_AZE() public {
        // Mock verifier that always succeeds for this simple test
        MockQuestVerifier mockVerifier = new MockQuestVerifier();
        mockVerifier.setShouldSucceed(true);

        vm.prank(admin);
        questManager.createQuest(
            "ipfs://aze",
            QuestManager.RewardType.AZE,
            address(aze),
            AZE_REWARD,
            address(mockVerifier),
            mockVerifier.verify.selector,
            true
        );

        uint256 balanceBefore = aze.balanceOf(user);
        vm.prank(user);
        questManager.claimReward(1);

        assertEq(aze.balanceOf(user), balanceBefore + AZE_REWARD);
        assertTrue(questManager.questCompleted(1, user));
    }

    function test_ClaimReward_SBT() public {
        MockQuestVerifier mockVerifier = new MockQuestVerifier();
        mockVerifier.setShouldSucceed(true);

        vm.prank(admin);
        questManager.createQuest(
            "ipfs://sbt",
            QuestManager.RewardType.SBT,
            address(sbt),
            SBT_ID,
            address(mockVerifier),
            mockVerifier.verify.selector,
            true
        );

        uint256 balanceBefore = sbt.userAchievements(user, SBT_ID);
        vm.prank(user);
        questManager.claimReward(1);

        assertEq(sbt.userAchievements(user, SBT_ID), balanceBefore + 1);
        assertTrue(questManager.questCompleted(1, user));
    }

    function test_ClaimReward_Reputation() public {
        MockQuestVerifier mockVerifier = new MockQuestVerifier();
        mockVerifier.setShouldSucceed(true);

        vm.prank(admin);
        questManager.createQuest(
            "ipfs://rep",
            QuestManager.RewardType.REPUTATION,
            address(reputationManager),
            REP_REWARD,
            address(mockVerifier),
            mockVerifier.verify.selector,
            true
        );

        uint256 reputationBefore = reputationManager.getReputation(user);
        vm.prank(user);
        questManager.claimReward(1);

        assertEq(reputationManager.getReputation(user), reputationBefore + REP_REWARD);
        assertTrue(questManager.questCompleted(1, user));
    }

    // --- Integration Tests with Real Verifiers ---

    function test_Integration_TokenBalanceQuest_Success() public {
        // 1. Admin creates quest using the real TokenBalanceVerifier
        vm.startPrank(admin);
        tokenVerifier.setMinBalance(AZE_REWARD); // Set the verification requirement
        questManager.createQuest(
            "ipfs://token",
            QuestManager.RewardType.SBT,
            address(sbt),
            SBT_ID,
            address(tokenVerifier),
            tokenVerifier.verify.selector,
            true
        );
        vm.stopPrank();

        // 2. Fund user with enough tokens to pass verification
        aze.mint(user, AZE_REWARD);

        // 3. User claims reward
        vm.prank(user);
        questManager.claimReward(1);

        // 4. Check that user received the SBT
        assertEq(sbt.userAchievements(user, SBT_ID), 1);
        assertTrue(questManager.questCompleted(1, user));
    }

    function test_Integration_TokenBalanceQuest_Failure() public {
        vm.startPrank(admin);
        tokenVerifier.setMinBalance(AZE_REWARD);
        questManager.createQuest(
            "ipfs://token",
            QuestManager.RewardType.SBT,
            address(sbt),
            SBT_ID,
            address(tokenVerifier),
            tokenVerifier.verify.selector,
            true
        );
        vm.stopPrank();

        // User does not have enough tokens
        vm.prank(user);
        vm.expectRevert(QuestManager.QuestManager__VerificationFailed.selector);
        questManager.claimReward(1);
    }

    function test_Integration_NftHolderQuest_Success() public {
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://nft",
            QuestManager.RewardType.REPUTATION,
            address(reputationManager),
            REP_REWARD,
            address(nftVerifier),
            nftVerifier.verify.selector,
            true
        );

        // Mint an NFT to the user so they pass verification
        nft.mint(user);

        vm.prank(user);
        questManager.claimReward(1);

        assertEq(reputationManager.getReputation(user), REP_REWARD);
        assertTrue(questManager.questCompleted(1, user));
    }

    function test_Integration_NftHolderQuest_Failure() public {
        vm.prank(admin);
        questManager.createQuest(
            "ipfs://nft",
            QuestManager.RewardType.REPUTATION,
            address(reputationManager),
            REP_REWARD,
            address(nftVerifier),
            nftVerifier.verify.selector,
            true
        );

        // User does not have the NFT
        vm.prank(user);
        vm.expectRevert(QuestManager.QuestManager__VerificationFailed.selector);
        questManager.claimReward(1);
    }
}
