// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./ProjectRegistry.sol";
import "./DynamicImpactCredit.sol";

// --- Custom Errors ---
error DMRVManager__ProjectNotActive();
error DMRVManager__RequestNotFound();
error DMRVManager__RequestAlreadyFulfilled();

/**
 * @title DMRVManager
 * @author Genci Mehmeti
 * @dev Manages the retrieval and processing of digital Monitoring, Reporting, and
 * Verification (dMRV) data. This contract acts as the bridge between off-chain
 * data sources (oracles) and the on-chain minting of `DynamicImpactCredit` tokens,
 * ensuring that only verified environmental impact results in token creation.
 * It is upgradeable using the UUPS pattern.
 */
contract DMRVManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // --- Roles ---
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32[] private _roles;

    // --- State variables ---
    ProjectRegistry public immutable projectRegistry;
    DynamicImpactCredit public immutable creditContract;

    // Mapping to track verification requests by request ID
    mapping(bytes32 => VerificationRequest) private _requests;

    uint256[50] private __gap;

    // Structure for tracking verification requests
    // Struct is packed to save gas on storage.
    struct VerificationRequest {
        bytes32 projectId; // 32 bytes - Slot 0
        // --- Packed into a single 32-byte slot (Slot 1) ---
        address requestor; // 20 bytes
        uint64 timestamp; // 8 bytes
        bool fulfilled; // 1 byte
    }

    // Structure for representing parsed verification data
    struct VerificationData {
        uint256 creditAmount;
        string metadataURI;
        bool updateMetadataOnly;
        bytes32 signature; // For validating that data came from an authorized source
    }

    // --- Events ---
    event VerificationRequested(bytes32 indexed requestId, bytes32 indexed projectId, address indexed requestor);
    event VerificationFulfilled(bytes32 indexed requestId, bytes32 indexed projectId, uint256 creditAmount);
    event AdminVerificationSubmitted(
        bytes32 indexed projectId, uint256 creditAmount, string metadataURI, bool updateMetadataOnly
    );
    event MetadataUpdated(bytes32 indexed projectId, string newURI);
    event CreditsMinted(bytes32 indexed projectId, address indexed owner, uint256 amount);
    event MissingProjectError(bytes32 indexed projectId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address projectRegistry_, address creditContract_) {
        if (projectRegistry_ == address(0) || creditContract_ == address(0)) {
            revert("Zero address not allowed");
        }
        projectRegistry = ProjectRegistry(projectRegistry_);
        creditContract = DynamicImpactCredit(creditContract_);
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with dependent contract addresses.
     * @dev Sets up roles and contract dependencies. The deployer is granted `DEFAULT_ADMIN_ROLE`,
     * `ORACLE_ROLE`, and `PAUSER_ROLE`. In a production environment, the `ORACLE_ROLE` would be
     * transferred to trusted oracle contracts.
     */
    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        // In a real deployment, this would be set to trusted oracle addresses
        _grantRole(ORACLE_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());

        _roles.push(DEFAULT_ADMIN_ROLE);
        _roles.push(ORACLE_ROLE);
        _roles.push(PAUSER_ROLE);
    }

    /**
     * @notice Initiates a request for dMRV data from an oracle for a given project.
     * @dev Emits a `VerificationRequested` event. For the MVP, this simulates an oracle request by
     * creating a request entry. In a production environment, this function would be expanded to
     * make a direct call to a decentralized oracle network like Chainlink.
     * The project must be in the `Active` state.
     * @param projectId The unique identifier of the project to verify.
     * @return requestId A unique ID for the verification request.
     */
    function requestVerification(bytes32 projectId) external nonReentrant whenNotPaused returns (bytes32 requestId) {
        if (!projectRegistry.isProjectActive(projectId)) revert DMRVManager__ProjectNotActive();

        // For MVP: Generate a simple request ID.
        // In production, this would come from the Chainlink request.
        requestId = keccak256(abi.encodePacked(projectId, _msgSender(), block.timestamp));

        _requests[requestId] = VerificationRequest({
            projectId: projectId,
            requestor: _msgSender(),
            timestamp: uint64(block.timestamp),
            fulfilled: false
        });

        emit VerificationRequested(requestId, projectId, _msgSender());

        // In a real implementation, we'd make a Chainlink request here.
        // For MVP purposes, we're simulating the oracle callback.

        return requestId;
    }

    /**
     * @notice Callback function for oracles to deliver verified dMRV data.
     * @dev This is a privileged function that can only be called by addresses with the `ORACLE_ROLE`.
     * It marks the request as fulfilled and processes the incoming data to mint new impact credit tokens
     * or update the metadata of existing ones. Emits a `VerificationFulfilled` event.
     * @param requestId The ID of the verification request being fulfilled.
     * @param data The raw, encoded verification data from the dMRV system.
     */
    function fulfillVerification(bytes32 requestId, bytes calldata data)
        external
        onlyRole(ORACLE_ROLE)
        nonReentrant
        whenNotPaused
    {
        VerificationRequest storage request = _requests[requestId];
        if (request.timestamp == 0) revert DMRVManager__RequestNotFound();
        if (request.fulfilled) revert DMRVManager__RequestAlreadyFulfilled();

        request.fulfilled = true;

        // Process the verification data
        VerificationData memory vData = parseVerificationData(data);

        // Act based on the verification data
        processVerification(request.projectId, request.requestor, vData);

        emit VerificationFulfilled(requestId, request.projectId, vData.creditAmount);
    }

    /**
     * @dev Internal function to process verified dMRV data. It either mints new
     * credits to the project owner or updates the metadata URI of the associated token.
     * @param projectId The project identifier.
     * @param data The parsed verification data.
     */
    function processVerification(bytes32 projectId, address, /* requestor */ VerificationData memory data) internal {
        if (data.updateMetadataOnly) {
            // Update metadata only
            creditContract.setTokenURI(projectId, data.metadataURI);
            emit MetadataUpdated(projectId, data.metadataURI);
        } else if (data.creditAmount > 0) {
            // Get project owner from registry to mint credits to them
            try projectRegistry.getProject(projectId) returns (ProjectRegistry.Project memory project) {
                // Mint new credits to the project owner
                creditContract.mintCredits(project.owner, projectId, data.creditAmount, data.metadataURI);
                emit CreditsMinted(projectId, project.owner, data.creditAmount);
            } catch {
                emit MissingProjectError(projectId);
            }
        }
    }

    /**
     * @dev Parses raw verification data from the oracle into a structured format.
     * @param data The raw byte data from the oracle.
     * @return A `VerificationData` struct.
     */
    function parseVerificationData(bytes calldata data) internal pure returns (VerificationData memory) {
        // A more robust decoding scheme.
        (uint256 creditAmount, bool updateMetadataOnly, bytes32 signature, string memory metadataURI) =
            abi.decode(data, (uint256, bool, bytes32, string));

        return VerificationData({
            creditAmount: creditAmount,
            metadataURI: metadataURI,
            updateMetadataOnly: updateMetadataOnly,
            signature: signature
        });
    }

    /**
     * @notice Admin function to manually submit verification data, bypassing the oracle.
     * @dev This is a privileged function for `DEFAULT_ADMIN_ROLE` holders. It is intended for
     * testing, emergency interventions, or manual data entry. It directly calls the internal
     * processing logic. Emits an `AdminVerificationSubmitted` event.
     * @param projectId The project identifier.
     * @param creditAmount Amount of credits to mint (can be 0).
     * @param metadataURI The new metadata URI to set.
     * @param updateMetadataOnly If true, only updates metadata without minting.
     */
    function adminSubmitVerification(
        bytes32 projectId,
        uint256 creditAmount,
        string calldata metadataURI,
        bool updateMetadataOnly
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (!projectRegistry.isProjectActive(projectId)) revert DMRVManager__ProjectNotActive();

        VerificationData memory vData = VerificationData({
            creditAmount: creditAmount,
            metadataURI: metadataURI,
            updateMetadataOnly: updateMetadataOnly,
            signature: bytes32(0) // Not needed for admin functions
        });

        processVerification(projectId, _msgSender(), vData);
        emit AdminVerificationSubmitted(projectId, creditAmount, metadataURI, updateMetadataOnly);
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
    function _authorizeUpgrade(address /* newImpl */ ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

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
}
