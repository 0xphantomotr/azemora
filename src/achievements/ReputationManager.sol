// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

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
contract ReputationManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // --- Custom Errors ---
    error ReputationManager__Unauthorized();

    // --- Roles ---
    /**
     * @dev Role granted to contracts that are allowed to add reputation to users.
     * Initially, this will be the QuestManager.
     */
    bytes32 public constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");

    // --- State ---
    /// @dev Mapping from a user's address to their total reputation score.
    mapping(address => uint256) public reputationScores;

    uint256[50] private __gap;

    // --- Events ---
    event ReputationAdded(address indexed user, address indexed source, uint256 amount, uint256 newTotal);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract.
     * @dev The deployer is granted admin and updater roles.
     * @param initialUpdater The initial address to be granted the REPUTATION_UPDATER_ROLE (e.g., QuestManager).
     */
    function initialize(address initialUpdater) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(REPUTATION_UPDATER_ROLE, initialUpdater);
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
        uint256 currentScore = reputationScores[user];
        uint256 newScore = currentScore + amount;
        reputationScores[user] = newScore;

        emit ReputationAdded(user, _msgSender(), amount, newScore);
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
