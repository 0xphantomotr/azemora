// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// --- Custom Errors ---
error AchievementsSBT__TransferDisabled();
error AchievementsSBT__URINotSetForAchievement();

/**
 * @title AchievementsSBT
 * @author Genci Mehmeti
 * @dev An ERC-1155 contract for issuing non-transferable Soulbound Tokens (SBTs)
 * as achievement badges within the Azemora ecosystem.
 *
 * Implements ERC-5192 for soulbound token compatibility. Transfers are disabled,
 * but an admin can revoke (burn) badges. Minting is restricted to authorized
 * minters (e.g., QuestManager, Governance).
 */
contract AchievementsSBT is
    Initializable,
    ERC1155Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    // --- Roles ---
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- State ---
    // Mapping from achievement ID (which is the tokenId) to its metadata URI.
    mapping(uint256 => string) private _achievementURIs;
    string private _contractURI;

    uint256[50] private __gap;

    // --- Events ---
    event AchievementURIUpdated(uint256 indexed achievementId, string newURI);
    event ContractURIUpdated(string newURI);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract.
     * @dev The deployer is granted admin, minter, and pauser roles.
     * @param contractURI_ The URI for the contract-level metadata.
     */
    function initialize(string memory contractURI_) public initializer {
        __ERC1155_init(""); // URI is set per-token, not with a base URI.
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(MINTER_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());
        _contractURI = contractURI_;
    }

    // --- Core SBT Logic ---

    /**
     * @notice Mints a new achievement badge (SBT) for a user.
     * @dev Can only be called by an address with `MINTER_ROLE`. Each achievement should
     * ideally be minted only once per user.
     * @param to The address of the user receiving the achievement.
     * @param achievementId The ID of the achievement to mint. This is the ERC-1155 tokenId.
     * @param amount The quantity to mint (typically 1 for SBTs).
     */
    function mintAchievement(address to, uint256 achievementId, uint256 amount)
        external
        onlyRole(MINTER_ROLE)
        whenNotPaused
    {
        _mint(to, achievementId, amount, "");
    }

    /**
     * @notice Revokes (burns) an achievement badge from a user.
     * @dev This is a privileged function for DAOs or admins to handle cases of error
     * or abuse. Can only be called by an address with the `DEFAULT_ADMIN_ROLE`.
     * @param from The address of the user whose badge is being revoked.
     * @param achievementId The ID of the achievement to burn.
     * @param amount The quantity to burn.
     */
    function revokeAchievement(address from, uint256 achievementId, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        _burn(from, achievementId, amount);
    }

    // --- Metadata Management ---

    /**
     * @notice Returns the metadata URI for a given achievement ID.
     * @param achievementId The ERC-1155 token ID representing the achievement.
     */
    function uri(uint256 achievementId) public view override returns (string memory) {
        string memory achievementURI = _achievementURIs[achievementId];
        if (bytes(achievementURI).length == 0) revert AchievementsSBT__URINotSetForAchievement();
        return achievementURI;
    }

    /**
     * @notice Sets or updates the metadata URI for a specific achievement.
     * @dev Can only be called by an address with `DEFAULT_ADMIN_ROLE`.
     * @param achievementId The ID of the achievement to update.
     * @param newURI The new metadata URI.
     */
    function setAchievementURI(uint256 achievementId, string calldata newURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _achievementURIs[achievementId] = newURI;
        emit AchievementURIUpdated(achievementId, newURI);
    }

    /**
     * @notice Returns the contract-level metadata URI.
     */
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /**
     * @notice Updates the contract-level metadata URI.
     * @dev Can only be called by an address with the `DEFAULT_ADMIN_ROLE`.
     */
    function setContractURI(string calldata newUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _contractURI = newUri;
        emit ContractURIUpdated(newUri);
    }

    // --- Pausable Logic ---

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- ERC-5192: Soulbound Token Standard ---

    /**
     * @notice Indicates that all tokens in this contract are permanently locked.
     * @dev Implements the ERC-5192 standard for soulbound tokens.
     * @return A boolean that is always true.
     */
    function locked(uint256 /*tokenId*/ ) public pure returns (bool) {
        return true;
    }

    // --- Overrides for Non-Transferability and Interface Support ---

    /**
     * @dev Overrides the internal `_update` function to enforce non-transferability.
     * Transfers are only allowed for minting (from address(0)) and burning (to address(0)).
     */
    function _update(address from, address to, uint256[] memory ids, uint256[] memory amounts)
        internal
        override
        whenNotPaused
    {
        if (from != address(0) && to != address(0)) {
            revert AchievementsSBT__TransferDisabled();
        }
        super._update(from, to, ids, amounts);
    }

    /**
     * @notice Declares support for ERC-1155, AccessControl, and ERC-5192 interfaces.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return interfaceId == 0xb45a3c0e || super.supportsInterface(interfaceId); // ERC-5192 Locked
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
