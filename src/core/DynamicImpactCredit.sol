// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./ProjectRegistry.sol";

/**
 * @title DynamicImpactCredit
 * @author Genci Mehmeti
 * @dev An ERC1155 token contract for creating dynamic environmental assets.
 * Each `tokenId`, derived from a `projectId`, represents a unique class of impact credit.
 * The contract stores a history of metadata URIs for each token, allowing its
 * attributes to evolve as new dMRV data is verified. Minting is restricted to
 * the `DMRVManager` contract, ensuring credits are only created based on validated impact.
 * It is upgradeable using the UUPS pattern.
 */
contract DynamicImpactCredit is ERC1155Upgradeable, AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    bytes32 public constant DMRV_MANAGER_ROLE = keccak256("DMRV_MANAGER_ROLE");
    bytes32 public constant METADATA_UPDATER_ROLE = keccak256("METADATA_UPDATER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32[] private _roles;

    mapping(uint256 => string[]) private _tokenURIs;
    string private _contractURI;
    IProjectRegistry public projectRegistry;

    uint256[50] private __gap;

    // --- Events ---
    event ContractURIUpdated(string newURI);
    event CreditsRetired(address indexed retirer, uint256 indexed tokenId, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // protect the impl
    }

    /**
     * @notice Initializes the contract, setting the contract URI and dependent contracts.
     * @dev Sets up roles and contract dependencies. The deployer is granted `DEFAULT_ADMIN_ROLE`
     * and `PAUSER_ROLE`. In a production environment, the other roles (`DMRV_MANAGER_ROLE`,
     * `METADATA_UPDATER_ROLE`) must be granted to their respective contracts.
     * @param contractURI_ The URI for the contract-level metadata.
     * @param projectRegistry_ The address of the `ProjectRegistry` contract.
     */
    function initialize(string memory contractURI_, address projectRegistry_) public initializer {
        __ERC1155_init(""); // base URI empty – each token has its own
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // This is required to make the initializer the admin.
        _grantRole(PAUSER_ROLE, _msgSender());
        _contractURI = contractURI_;
        projectRegistry = IProjectRegistry(projectRegistry_);

        _roles.push(DEFAULT_ADMIN_ROLE);
        _roles.push(DMRV_MANAGER_ROLE);
        _roles.push(METADATA_UPDATER_ROLE);
        _roles.push(PAUSER_ROLE);
    }

    /**
     * @notice Mints a new batch of impact credits for a verified project.
     * @dev Can only be called by an address with `DMRV_MANAGER_ROLE`. The `tokenId` is the `uint256`
     * cast of the `projectId`. This function adds the new metadata URI to the token's history.
     * The project must be `Active` in the `ProjectRegistry`.
     * @param to The address to receive the new credits.
     * @param projectId The project ID, used to derive the `tokenId`.
     * @param amount The quantity of credits to mint.
     * @param newUri The new metadata URI for this batch, pointing to dMRV data.
     */
    function mintCredits(address to, bytes32 projectId, uint256 amount, string calldata newUri)
        external
        onlyRole(DMRV_MANAGER_ROLE)
        whenNotPaused
    {
        require(projectRegistry.isProjectActive(projectId), "NOT_ACTIVE");

        uint256 tokenId = uint256(projectId);
        _mint(to, tokenId, amount, "");

        // Always update the URI by pushing to the history array
        _tokenURIs[tokenId].push(newUri);

        emit URI(newUri, tokenId);
    }

    /**
     * @notice Updates a token's metadata by adding a new URI to its history.
     * @dev Can only be called by an address with `METADATA_UPDATER_ROLE`. This allows for
     * impact data to be updated without minting new tokens. Emits a `URI` event.
     * @param id The project ID (`bytes32`) of the token to update.
     * @param newUri The new metadata URI to add to the token's history.
     */
    function setTokenURI(bytes32 id, string calldata newUri) external onlyRole(METADATA_UPDATER_ROLE) whenNotPaused {
        uint256 tokenId = uint256(id);
        _tokenURIs[tokenId].push(newUri);
        emit URI(newUri, tokenId);
    }

    /**
     * @notice Returns the latest metadata URI for a given token ID.
     * @dev This points to the most up-to-date off-chain metadata JSON. The token must exist.
     * @param id The token ID to query.
     * @return The latest metadata URI string.
     */
    function uri(uint256 id) public view override returns (string memory) {
        string[] storage uris = _tokenURIs[id];
        require(uris.length > 0, "URI not set for token");
        return uris[uris.length - 1];
    }

    /**
     * @notice Retrieves the entire history of metadata URIs for a token.
     * @dev Provides a transparent, on-chain audit trail of all changes to a token's
     * verified data.
     * @param id The token ID to query.
     * @return An array of all historical metadata URI strings.
     */
    function getTokenURIHistory(uint256 id) public view returns (string[] memory) {
        return _tokenURIs[id];
    }

    /**
     * @notice Retires (burns) a specified amount of credits from an owner's balance.
     * @dev Any credit holder can call this to permanently retire their assets, preventing re-sale
     * and "double counting" of the environmental claim. The caller must be the owner of the tokens
     * or be approved to manage them. Emits a `CreditsRetired` event.
     * @param from The address of the credit holder.
     * @param id The project ID (`bytes32`) of the credits to retire.
     * @param amount The quantity of credits to retire.
     */
    function retire(address from, bytes32 id, uint256 amount) external virtual whenNotPaused {
        require(from == _msgSender() || isApprovedForAll(from, _msgSender()), "NOT_AUTHORIZED");
        uint256 tokenId = uint256(id);
        _burn(from, tokenId, amount);
        emit CreditsRetired(_msgSender(), tokenId, amount);
    }

    /**
     * @notice Gets all the roles held by a specific account.
     * @dev Provides an easy way for UIs and other tools to check permissions.
     * @param account The address to check.
     * @return A list of role identifiers held by the account.
     */
    function getRoles(address account) external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _roles.length; i++) {
            if (hasRole(_roles[i], account)) {
                count++;
            }
        }

        bytes32[] memory roles = new bytes32[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < _roles.length; i++) {
            if (hasRole(_roles[i], account)) {
                roles[index++] = _roles[i];
            }
        }
        return roles;
    }

    /**
     * @notice Returns the contract-level metadata URI.
     * @dev This URI points to a JSON file that describes the contract, following the ERC-1155 metadata standard.
     */
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /**
     * @notice Updates the contract-level metadata URI.
     * @dev Can only be called by an address with the `DEFAULT_ADMIN_ROLE`.
     * Emits a `ContractURIUpdated` event.
     * @param newUri The new contract-level URI.
     */
    function setContractURI(string calldata newUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _contractURI = newUri;
        emit ContractURIUpdated(newUri);
    }

    /**
     * @notice Pauses all state-changing functions in the contract.
     * @dev Can only be called by an address with the `PAUSER_ROLE`.
     * This is a critical safety feature to halt activity in case of an emergency.
     * Emits a `Paused` event.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Lifts the pause on the contract, resuming normal operations.
     * @dev Can only be called by an address with the `PAUSER_ROLE`.
     * Emits an `Unpaused` event.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address /* newImpl */ ) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /* ---------- interface fan-in ---------- */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Mints multiple batches of impact credits.
     * @dev A gas-efficient alternative to `mintCredits` for minting credits for multiple projects
     * at once. Can only be called by an address with `DMRV_MANAGER_ROLE`. All projects must be active.
     * @param to The address to receive all the new credits.
     * @param ids An array of project IDs.
     * @param amounts An array of amounts to mint for each corresponding project ID.
     * @param uris An array of initial metadata URIs for each corresponding project ID.
     */
    function batchMintCredits(
        address to,
        bytes32[] calldata ids,
        uint256[] calldata amounts,
        string[] calldata uris // 1-to-1 with ids
    ) external onlyRole(DMRV_MANAGER_ROLE) whenNotPaused {
        require(ids.length == amounts.length && ids.length == uris.length, "LENGTH_MISMATCH");

        uint256[] memory tokenIds = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length;) {
            require(projectRegistry.isProjectActive(ids[i]), "DIC: PROJECT_NOT_ACTIVE");
            tokenIds[i] = uint256(ids[i]);
            unchecked {
                ++i;
            }
        }

        _mintBatch(to, tokenIds, amounts, "");

        for (uint256 i = 0; i < ids.length;) {
            // Only add the URI if it's the very first mint for that token
            if (_tokenURIs[tokenIds[i]].length == 0) {
                _tokenURIs[tokenIds[i]].push(uris[i]);
                emit URI(uris[i], tokenIds[i]);
            }
            unchecked {
                ++i;
            }
        }
    }
}
