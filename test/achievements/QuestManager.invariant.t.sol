// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {QuestManagerTest} from "./QuestManager.t.sol";
import {QuestManager} from "../../src/achievements/QuestManager.sol";

/**
 * @title QuestManagerHandler
 * @dev A stateful handler for the QuestManager invariant tests.
 * The fuzzer will call functions on this contract with random inputs,
 * which then get forwarded to the actual QuestManager contract.
 * It maintains a "shadow state" to validate invariants.
 */
contract QuestManagerHandler is Test {
    QuestManager internal questManager;
    address internal admin;

    // Shadow state to track what the handler believes is true
    mapping(uint256 => QuestManager.Quest) internal _quests;
    mapping(uint256 => mapping(address => bool)) public questCompleted;
    uint256[] public createdQuestIds;
    uint256 public createdQuestCount;

    constructor(QuestManager _questManager, address _admin) {
        questManager = _questManager;
        admin = _admin;
    }

    // New getter function that returns the whole struct
    function getQuest(uint256 questId) external view returns (QuestManager.Quest memory) {
        return _quests[questId];
    }

    /**
     * @dev Fuzzer can call this to simulate an admin creating a quest.
     */
    function createQuest(string memory uri, QuestManager.RewardType rType, bool isActive) public {
        vm.prank(admin);
        uint256 questId = questManager.getNextQuestId();

        // For simplicity, we use the test's mock contracts for rewards/verification
        address rewardContract = address(0);
        if (rType == QuestManager.RewardType.AZE) rewardContract = 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a;
        else if (rType == QuestManager.RewardType.SBT) rewardContract = 0x48949828D1f7e0b3225A7c42D4e4A452932375B4;
        else rewardContract = 0x8226a51DA1d722D33a2A8b14A0b5a278913952A2;

        address verifierContract = 0xa0Cb889707d426A7A386870A03bc70d1b0697598;
        bytes4 verifierHook = bytes4(keccak256("verify(address)"));

        try questManager.createQuest(uri, rType, rewardContract, 1, verifierContract, verifierHook, isActive) {
            QuestManager.Quest memory newQuest =
                QuestManager.Quest(questId, uri, rType, rewardContract, 1, verifierContract, verifierHook, isActive);
            _quests[questId] = newQuest;
            createdQuestIds.push(questId);
            createdQuestCount++;
        } catch {}
    }

    /**
     * @dev Fuzzer can call this to simulate toggling a quest's status.
     */
    function toggleQuestStatus(uint256 questId, bool isActive) public {
        if (questId == 0 || _quests[questId].id == 0) return; // Use internal variable

        vm.prank(admin);
        try questManager.toggleQuestStatus(questId, isActive) {
            _quests[questId].isActive = isActive;
        } catch {}
    }

    /**
     * @dev Fuzzer can call this to simulate a user claiming a reward.
     */
    function claimReward(uint256 questId, address user) public {
        if (questId == 0 || _quests[questId].id == 0) return; // Use internal variable

        // The mock verifier needs to be set to succeed for a claim to work
        // In a real scenario, this would depend on the quest's state
        // For fuzzing, we assume it can be successful
        // MockQuestVerifier(quests[questId].verificationContract).setShouldSucceed(true);

        vm.prank(user);
        try questManager.claimReward(questId) {
            // If claim succeeds, update our shadow state.
            questCompleted[questId][user] = true;
        } catch {}
    }
}

/**
 * @title QuestManagerInvariantTest
 * @dev This contract defines system-wide invariants for the QuestManager.
 */
contract QuestManagerInvariantTest is QuestManagerTest {
    QuestManagerHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new QuestManagerHandler(questManager, admin);

        // Target the handler, not the questManager directly
        targetContract(address(handler));
    }

    /**
     * @dev INVARIANT: The `questCompleted` state in the real contract must always
     * match the state tracked in our handler. This ensures no double claims or
     * other illegal state changes.
     */
    function invariant_completionStateMatches() public view {
        for (uint256 i = 0; i < handler.createdQuestCount(); i++) {
            uint256 questId = handler.createdQuestIds(i);
            // We can't check all users, so we check a specific one the fuzzer knows about.
            // A more advanced handler could track all users it has interacted with.
            address user = 0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D;
            assertEq(questManager.questCompleted(questId, user), handler.questCompleted(questId, user));
        }
    }

    /**
     * @dev INVARIANT: The core data of a quest cannot be changed after creation.
     */
    function invariant_questDataIsImmutable() public view {
        for (uint256 i = 0; i < handler.createdQuestCount(); i++) {
            uint256 questId = handler.createdQuestIds(i);
            QuestManager.Quest memory shadowQuest = handler.getQuest(questId);
            QuestManager.Quest memory realQuest = questManager.getQuest(questId);

            assertEq(realQuest.id, shadowQuest.id);
            assertEq(realQuest.descriptionURI, shadowQuest.descriptionURI);
            assertEq(uint256(realQuest.rewardType), uint256(shadowQuest.rewardType));
            assertEq(realQuest.rewardContract, shadowQuest.rewardContract);
            assertEq(realQuest.rewardIdOrAmount, shadowQuest.rewardIdOrAmount);
        }
    }

    /**
     * @dev INVARIANT: A reward for an inactive quest can never be claimed.
     */
    function invariant_inactiveQuestsCannotBeClaimed() public view {
        for (uint256 i = 0; i < handler.createdQuestCount(); i++) {
            uint256 questId = handler.createdQuestIds(i);
            QuestManager.Quest memory realQuest = questManager.getQuest(questId);

            if (!realQuest.isActive) {
                address user = 0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D;
                assertFalse(questManager.questCompleted(questId, user), "A completed quest was found to be inactive");
            }
        }
    }
}
