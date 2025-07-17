// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
// This is the corrected import path, pointing to the non-upgradeable library's file
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interfaces for contracts QuestManager interacts with
interface IAchievementSBT {
    function mintAchievement(address user, uint256 achievementId) external;
}

interface IReputationManager {
    function addReputation(address user, uint256 amount) external;
}

// A generic interface for on-chain verification hooks
interface IQuestVerifier {
    function verify(address user) external view returns (bool);
}

/**
 * @title QuestManager
 * @author Genci Mehmeti
 * @dev Manages quests to drive user engagement. It allows defining challenges,
 * verifying user completion via on-chain hooks or admin triggers, and granting
 * rewards such as SBTs, AZE tokens, or reputation points.
 * It is upgradeable using the UUPS pattern.
 */
contract QuestManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    // --- Custom Errors ---
    error QuestManager__QuestAlreadyCompleted();
    error QuestManager__QuestNotActive();
    error QuestManager__QuestNotFound();
    error QuestManager__VerificationFailed();
    error QuestManager__InvalidRewardType();
    error QuestManager__RewardTransferFailed();
    error QuestManager__Unauthorized();
    error QuestManager__InvalidAddress();
    error QuestManager__QuestAlreadyExists();

    using SafeERC20 for IERC20;

    bytes32 public constant QUEST_ADMIN_ROLE = keccak256("QUEST_ADMIN_ROLE");

    enum RewardType {
        AZE,
        SBT,
        REPUTATION
    }

    struct Quest {
        uint256 id;
        string descriptionURI; // URI to JSON for quest details
        RewardType rewardType;
        address rewardContract; // Address of the AZE/SBT/Reputation contract
        uint256 rewardIdOrAmount; // SBT ID or amount of AZE/Reputation
        address verificationContract; // The contract to call for verification
        bytes4 verificationHook; // The function selector (e.g., IQuestVerifier.verify.selector)
        bool isActive;
    }

    mapping(uint256 => Quest) private _quests;
    mapping(uint256 => mapping(address => bool)) public questCompleted;
    uint256 private _nextQuestId;

    uint256[50] private __gap;

    // --- Events ---
    event QuestCreated(uint256 indexed questId, RewardType rewardType);
    event QuestStatusToggled(uint256 indexed questId, bool isActive);
    event QuestRewardClaimed(address indexed user, uint256 indexed questId);
    event AdminQuestCompletion(address indexed user, uint256 indexed questId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(QUEST_ADMIN_ROLE, _msgSender());
        _nextQuestId = 1;
    }

    // --- Admin Functions ---

    /**
     * @notice Creates a new quest.
     * @dev Only callable by QUEST_ADMIN_ROLE.
     */
    function createQuest(
        string calldata descriptionURI,
        RewardType rewardType,
        address rewardContract,
        uint256 rewardIdOrAmount,
        address verificationContract,
        bytes4 verificationHook,
        bool isActive
    ) external onlyRole(QUEST_ADMIN_ROLE) {
        if (rewardContract == address(0) || verificationContract == address(0)) {
            revert QuestManager__InvalidAddress();
        }
        uint256 questId = _nextQuestId;
        _quests[questId] = Quest({
            id: questId,
            descriptionURI: descriptionURI,
            rewardType: rewardType,
            rewardContract: rewardContract,
            rewardIdOrAmount: rewardIdOrAmount,
            verificationContract: verificationContract,
            verificationHook: verificationHook,
            isActive: isActive
        });
        _nextQuestId++;
        emit QuestCreated(questId, rewardType);
    }

    /**
     * @notice Activates or deactivates a quest.
     * @dev Only callable by QUEST_ADMIN_ROLE.
     */
    function toggleQuestStatus(uint256 questId, bool isActive) external onlyRole(QUEST_ADMIN_ROLE) {
        if (_quests[questId].id == 0) revert QuestManager__QuestNotFound();
        _quests[questId].isActive = isActive;
        emit QuestStatusToggled(questId, isActive);
    }

    /**
     * @notice Allows an admin/oracle to manually mark a quest as complete for a user.
     * @dev Useful for quests with off-chain completion criteria.
     */
    function adminMarkQuestCompleted(address user, uint256 questId) external onlyRole(QUEST_ADMIN_ROLE) nonReentrant {
        if (_quests[questId].id == 0) revert QuestManager__QuestNotFound();
        if (questCompleted[questId][user]) revert QuestManager__QuestAlreadyCompleted();

        questCompleted[questId][user] = true;
        _grantReward(user, _quests[questId]);

        emit AdminQuestCompletion(user, questId);
    }

    /**
     * @notice Allows an admin to withdraw any ERC20 tokens from this contract.
     * @dev Useful for managing funds or recovering accidentally sent tokens.
     */
    function withdrawTokens(address tokenAddress, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(tokenAddress).safeTransfer(_msgSender(), amount);
    }

    // --- User Functions ---

    /**
     * @notice Allows a user to claim a reward for a completed quest.
     * @dev The function verifies completion by calling the quest's verification hook.
     */
    function claimReward(uint256 questId) external nonReentrant {
        Quest memory quest = _quests[questId];

        if (quest.id == 0) revert QuestManager__QuestNotFound();
        if (!quest.isActive) revert QuestManager__QuestNotActive();
        if (questCompleted[questId][_msgSender()]) revert QuestManager__QuestAlreadyCompleted();

        // On-chain verification
        bool success;
        bytes memory result;
        (success, result) =
            quest.verificationContract.staticcall(abi.encodeWithSelector(quest.verificationHook, _msgSender()));

        if (!success) {
            // Re-throw the error from the verifier contract if any
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        bool verified = abi.decode(result, (bool));
        if (!verified) revert QuestManager__VerificationFailed();

        questCompleted[questId][_msgSender()] = true;
        _grantReward(_msgSender(), quest);

        emit QuestRewardClaimed(_msgSender(), questId);
    }

    // --- Internal Functions ---

    function _grantReward(address user, Quest memory quest) internal {
        if (quest.rewardType == RewardType.AZE) {
            IERC20(quest.rewardContract).safeTransfer(user, quest.rewardIdOrAmount);
        } else if (quest.rewardType == RewardType.SBT) {
            IAchievementSBT(quest.rewardContract).mintAchievement(user, quest.rewardIdOrAmount);
        } else if (quest.rewardType == RewardType.REPUTATION) {
            IReputationManager(quest.rewardContract).addReputation(user, quest.rewardIdOrAmount);
        } else {
            revert QuestManager__InvalidRewardType();
        }
    }

    // --- View Functions ---

    function getQuest(uint256 questId) external view returns (Quest memory) {
        if (_quests[questId].id == 0) revert QuestManager__QuestNotFound();
        return _quests[questId];
    }

    function getNextQuestId() external view returns (uint256) {
        return _nextQuestId;
    }

    // --- UUPS Upgrade ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
