// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./ProjectRegistry.sol";

// --- Custom Errors ---
error DynamicImpactCredit__ProjectNotActive();
error DynamicImpactCredit__CredentialNotSet();
error DynamicImpactCredit__NotAuthorized();
error DynamicImpactCredit__LengthMismatch();

/**
 * @title DynamicImpactCredit
 * @author Genci Mehmeti
 * @dev An ERC1155 token contract for creating dynamic environmental assets.
 * Each `tokenId`, derived from a `projectId`, represents a unique class of impact credit.
 * The contract stores a history of credential CIDs for each token, allowing its
 * attributes to evolve as new dMRV data is verified. Minting is restricted to
 * the `DMRVManager` contract, ensuring credits are only created based on validated impact.
 * It is upgradeable using the UUPS pattern.
 */
contract DynamicImpactCredit is ERC1155Upgradeable, AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    function DMRV_MANAGER_ROLE() public pure returns (bytes32) {
        return keccak256("DMRV_MANAGER_ROLE");
    }

    function BURNER_ROLE() public pure returns (bytes32) {
        return keccak256("BURNER_ROLE");
    }

    function METADATA_UPDATER_ROLE() public pure returns (bytes32) {
        return keccak256("METADATA_UPDATER_ROLE");
    }

    function PAUSER_ROLE() public pure returns (bytes32) {
        return keccak256("PAUSER_ROLE");
    }

    bytes32[] private _roles;

    mapping(uint256 => string[]) private _credentialCIDs;
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
     * @notice Initializes the contract, setting the project registry and base URI.
     * @param projectRegistryAddress The address of the ProjectRegistry contract.
     * @param contractURI_ The base URI for all token types.
     */
    function initializeDynamicImpactCredit(address projectRegistryAddress, string memory contractURI_)
        public
        initializer
    {
        __ERC1155_init(contractURI_);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(DMRV_MANAGER_ROLE(), _msgSender()); // Initially grant to deployer
        _grantRole(BURNER_ROLE(), _msgSender()); // Initially grant to deployer

        projectRegistry = IProjectRegistry(projectRegistryAddress);

        _roles.push(DMRV_MANAGER_ROLE());
        _roles.push(BURNER_ROLE());
        _roles.push(METADATA_UPDATER_ROLE());
        _roles.push(PAUSER_ROLE());
        _roles.push(DEFAULT_ADMIN_ROLE);
    }

    /**
     * @notice Mints a new batch of impact credits for a verified project.
     * @dev Can only be called by an address with `DMRV_MANAGER_ROLE`. The `tokenId` is the `uint256`
     * cast of the `projectId`. This function adds the new credential CID to the token's history.
     * The project must be `Active` in the `ProjectRegistry`.
     * @param to The address to receive the new credits.
     * @param projectId The project ID, used to derive the `tokenId`.
     * @param amount The quantity of credits to mint.
     * @param credentialCID The new credential CID for this batch, pointing to a signed Verifiable Credential.
     */
    function mintCredits(address to, bytes32 projectId, uint256 amount, string calldata credentialCID)
        external
        onlyRole(DMRV_MANAGER_ROLE())
        whenNotPaused
    {
        if (!projectRegistry.isProjectActive(projectId)) revert DynamicImpactCredit__ProjectNotActive();

        uint256 tokenId = uint256(projectId);
        _credentialCIDs[tokenId].push(credentialCID);
        _mint(to, tokenId, amount, "");

        emit URI(credentialCID, tokenId);
    }

    /**
     * @notice Mints batches of impact credits for multiple verified projects.
     * @dev Can only be called by an address with `DMRV_MANAGER_ROLE`.
     * The length of `projectIds`, `amounts`, and `credentialCIDs` arrays must be the same.
     * @param to The address to receive the new credits.
     * @param projectIds The array of project IDs, used to derive the `tokenIds`.
     * @param amounts The array of quantities of credits to mint for each project.
     * @param credentialCIDs The array of new credential CIDs for each batch.
     */
    function batchMintCredits(
        address to,
        bytes32[] calldata projectIds,
        uint256[] calldata amounts,
        string[] calldata credentialCIDs
    ) external onlyRole(DMRV_MANAGER_ROLE()) whenNotPaused {
        uint256 len = projectIds.length;
        if (len != amounts.length || len != credentialCIDs.length) {
            revert DynamicImpactCredit__LengthMismatch();
        }

        uint256[] memory tokenIds = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            bytes32 projectId = projectIds[i];
            if (!projectRegistry.isProjectActive(projectId)) {
                revert DynamicImpactCredit__ProjectNotActive();
            }
            uint256 tokenId = uint256(projectId);
            tokenIds[i] = tokenId;

            // Effect
            _credentialCIDs[tokenId].push(credentialCIDs[i]);
            emit URI(credentialCIDs[i], tokenId);
        }

        // Interaction
        _mintBatch(to, tokenIds, amounts, "");
    }

    /**
     * @notice Burns credits from an account.
     * @dev Can only be called by an address with `BURNER_ROLE`. This is used by the system
     * to reverse fraudulent credit minting events.
     * @param from The address holding the credits to be burned.
     * @param projectId The project ID (`bytes32`) of the credits to burn.
     * @param amount The quantity of credits to burn.
     */
    function burnCredits(address from, bytes32 projectId, uint256 amount)
        external
        onlyRole(BURNER_ROLE())
        whenNotPaused
    {
        uint256 tokenId = uint256(projectId);
        _burn(from, tokenId, amount);
    }

    /**
     * @notice Updates a token's metadata by adding a new credential CID to its history.
     * @dev Can only be called by an address with `METADATA_UPDATER_ROLE`. This allows for
     * impact data to be updated without minting new tokens. Emits a `URI` event.
     * @param id The project ID (`bytes32`) of the token to update.
     * @param newCredentialCID The new credential CID to add to the token's history.
     */
    function updateCredentialCID(bytes32 id, string calldata newCredentialCID)
        external
        onlyRole(METADATA_UPDATER_ROLE())
        whenNotPaused
    {
        uint256 tokenId = uint256(id);
        _credentialCIDs[tokenId].push(newCredentialCID);
        emit URI(newCredentialCID, tokenId);
    }

    /**
     * @notice Returns the latest metadata URI for a given token ID.
     * @dev This points to the most up-to-date off-chain metadata (the Verifiable Credential). The token must exist.
     * @param id The token ID to query.
     * @return The latest credential CID string.
     */
    function uri(uint256 id) public view override returns (string memory) {
        string[] storage cids = _credentialCIDs[id];
        uint256 cidsLength = cids.length;
        if (cidsLength == 0) revert DynamicImpactCredit__CredentialNotSet();
        return cids[cidsLength - 1];
    }

    /**
     * @notice Retrieves the entire history of credential CIDs for a token.
     * @dev Provides a transparent, on-chain audit trail of all changes to a token's
     * verified data.
     * @param id The token ID to query.
     * @return An array of all historical credential CID strings.
     */
    function getCredentialCIDHistory(uint256 id) public view returns (string[] memory) {
        return _credentialCIDs[id];
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
    function retire(address from, bytes32 id, uint256 amount) public virtual whenNotPaused {
        if (from != _msgSender() && !isApprovedForAll(from, _msgSender())) revert DynamicImpactCredit__NotAuthorized();
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
        uint256 rolesLength = _roles.length;
        uint256 count = 0;
        for (uint256 i = 0; i < rolesLength; i++) {
            if (hasRole(_roles[i], account)) {
                count++;
            }
        }

        if (count == 0) {
            return new bytes32[](0);
        }

        bytes32[] memory roles = new bytes32[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < rolesLength; i++) {
            if (hasRole(_roles[i], account)) {
                roles[index++] = _roles[i];
                // Optimization: stop looping once all roles have been found.
                if (index == count) break;
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
    function pause() external onlyRole(PAUSER_ROLE()) {
        _pause();
    }

    /**
     * @notice Lifts the pause on the contract, resuming normal operations.
     * @dev Can only be called by an address with the `PAUSER_ROLE`.
     * Emits an `Unpaused` event.
     */
    function unpause() external onlyRole(PAUSER_ROLE()) {
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
}
