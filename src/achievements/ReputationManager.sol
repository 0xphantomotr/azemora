// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IReputationManager.sol";

/**
 * @title ReputationManager
 * @author Azemora Core Team
 * @dev Manages user reputation scores within the Azemora ecosystem.
 *
 * This contract serves as the central ledger for reputation points, which are
 * awarded for completing quests and other positive contributions. Reputation is
 * non-transferable and can only be increased by authorized contracts.
 * It is upgradeable using the UUPS pattern.
 */
contract ReputationManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IReputationManager {
    // --- Custom Errors ---
    error ReputationManager__Unauthorized();
    error ReputationManager__AmountCannotBeZero();
    error ReputationManager__ReputationCannotGoNegative();

    // --- Roles ---
    /**
     * @dev Role granted to contracts that are allowed to add reputation to users.
     * Initially, this will be the QuestManager.
     */
    bytes32 public constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");

    /**
     * @dev Role granted to contracts that can slash (reduce) user reputation.
     * This will be the VerifierManager.
     */
    bytes32 public constant REPUTATION_SLASHER_ROLE = keccak256("REPUTATION_SLASHER_ROLE");

    // --- State ---
    /// @dev Mapping from a user's address to their total reputation score.
    mapping(address => uint256) public reputationScores;

    uint256[50] private __gap;

    // --- Events ---
    event ReputationAdded(address indexed user, address indexed source, uint256 amount, uint256 newTotal);
    event ReputationSlashed(address indexed user, address indexed source, uint256 amount, uint256 newTotal);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract.
     * @dev The deployer is granted admin and updater roles.
     * @param initialUpdater The initial address to be granted the REPUTATION_UPDATER_ROLE (e.g., QuestManager).
     * @param initialSlasher The initial address to be granted the REPUTATION_SLASHER_ROLE (e.g., VerifierManager).
     */
    function initialize(address initialUpdater, address initialSlasher) public initializer {
        __ReputationManager_init(initialUpdater, initialSlasher);
    }

    function __ReputationManager_init(address initialUpdater, address initialSlasher) internal onlyInitializing {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReputationManager_init_unchained(initialUpdater, initialSlasher);
    }

    function __ReputationManager_init_unchained(address initialUpdater, address initialSlasher)
        internal
        onlyInitializing
    {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(REPUTATION_UPDATER_ROLE, initialUpdater);
        _grantRole(REPUTATION_SLASHER_ROLE, initialSlasher);
    }

    // --- Core Logic ---

    /**
     * @notice Adds reputation points to a user's score.
     * @dev Can only be called by an address with `REPUTATION_UPDATER_ROLE`.
     * The caller (`_msgSender()`) is logged as the source of the update for traceability.
     * @param user The address of the user receiving the reputation.
     * @param amount The number of points to add.
     */
    function addReputation(address user, uint256 amount) external onlyRole(REPUTATION_UPDATER_ROLE) {
        if (amount == 0) revert ReputationManager__AmountCannotBeZero();
        uint256 currentScore = reputationScores[user];
        uint256 newScore = currentScore + amount;
        reputationScores[user] = newScore;

        emit ReputationAdded(user, _msgSender(), amount, newScore);
    }

    /**
     * @notice Slashes (reduces) reputation points from a user's score.
     * @dev Can only be called by an address with `REPUTATION_SLASHER_ROLE`.
     * The caller (`_msgSender()`) is logged as the source of the update for traceability.
     * @param user The address of the user whose reputation is being slashed.
     * @param amount The number of points to subtract.
     */
    function slashReputation(address user, uint256 amount) external onlyRole(REPUTATION_SLASHER_ROLE) {
        if (amount == 0) revert ReputationManager__AmountCannotBeZero();
        uint256 currentScore = reputationScores[user];
        if (amount > currentScore) revert ReputationManager__ReputationCannotGoNegative();

        uint256 newScore = currentScore - amount;
        reputationScores[user] = newScore;

        emit ReputationSlashed(user, _msgSender(), amount, newScore);
    }

    // --- View Functions ---

    /**
     * @notice Retrieves the current reputation score for a given user.
     * @param user The address of the user.
     * @return The user's total reputation score.
     */
    function getReputation(address user) external view returns (uint256) {
        return reputationScores[user];
    }

    // --- UUPS Upgrade ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
