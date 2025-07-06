// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./interfaces/IProjectRegistry.sol";
import "./DynamicImpactCredit.sol";
import "./interfaces/IVerifierModule.sol";
import "./interfaces/IMethodologyRegistry.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

// --- Custom Errors ---
error DMRVManager__ProjectNotActive();
error DMRVManager__ModuleNotRegistered();
error DMRVManager__ModuleAlreadyRegistered(bytes32 moduleType);
error DMRVManager__CallerNotRegisteredModule();
error DMRVManager__ZeroAddress();
error DMRVManager__ClaimNotFoundOrAlreadyFulfilled();
error DMRVManager__MethodologyNotValid();
error DMRVManager__RegistryNotSet();
error DMRVManager__NothingToReverse();
error DMRVManager__InvalidQuantitativeOutcome();

/**
 * @title DMRVManager
 * @author Genci Mehmeti
 * @dev Manages the retrieval and processing of digital Monitoring, Reporting, and
 * Verification (dMRV) data. This contract acts as a "router", delegating verification
 * tasks to specialized, registered verifier modules. It then processes the trusted
 * outcomes from these modules to mint `DynamicImpactCredit` tokens.
 * It is upgradeable using the UUPS pattern.
 */
contract DMRVManager is
    Initializable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // --- Roles ---
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MODULE_ADMIN_ROLE = keccak256("MODULE_ADMIN_ROLE");
    bytes32 public constant REVERSER_ROLE = keccak256("REVERSER_ROLE");

    // --- State variables ---
    IProjectRegistry public projectRegistry;
    DynamicImpactCredit public creditContract;
    IMethodologyRegistry public methodologyRegistry;

    // Mapping from a module type identifier to its deployed contract address
    mapping(bytes32 => address) public verifierModules;
    // Mapping from a specific claim ID to the module type that is handling it
    mapping(bytes32 => bytes32) private _claimToModuleType;
    // Stores the details of an active verification request.
    mapping(bytes32 => Verification) public verifications;
    // Records of fulfilled verifications to enable reversals.
    mapping(bytes32 => FulfillmentRecord) public fulfillmentRecords;

    // Adjusted gap to maintain storage layout for UUPS proxy compatibility
    uint256[46] private __gap;

    // --- Data Structures ---
    struct FulfillmentRecord {
        address recipient;
        uint256 creditAmount;
        uint256 quantitativeOutcome; // The percentage outcome that led to this amount
    }

    struct Verification {
        bytes32 projectId;
        string evidenceURI;
        uint256 amount; // The originally requested credit amount
    }

    // Structure for representing parsed verification data from a module
    struct VerificationData {
        uint256 quantitativeOutcome; // e.g., 85 for 85%
        bool wasArbitrated;
        bytes32 arbitrationDisputeId;
        string credentialCID;
    }

    // --- Events ---
    event VerificationDelegated(
        bytes32 indexed claimId,
        bytes32 indexed projectId,
        bytes32 indexed moduleType,
        address moduleAddress,
        uint256 amount
    );
    event VerificationFulfilled(
        bytes32 indexed claimId,
        bytes32 indexed projectId,
        bytes32 indexed moduleType,
        uint256 quantitativeOutcome,
        uint256 mintedAmount
    );
    event AdminVerificationSubmitted(
        bytes32 indexed projectId, uint256 creditAmount, string credentialCID, bool updateMetadataOnly
    );
    event CredentialCIDUpdated(bytes32 indexed projectId, string newCID);
    event CreditsMinted(bytes32 indexed projectId, address indexed owner, uint256 amount);
    event CreditsReversed(bytes32 indexed claimId, address indexed recipient, uint256 amount);
    event MissingProjectError(bytes32 indexed projectId);
    event VerifierModuleRegistered(bytes32 indexed moduleType, address indexed moduleAddress);
    event VerifierModuleRemoved(bytes32 indexed moduleType);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with dependent contract addresses.
     * @dev Sets up roles and contract dependencies. The deployer is granted `DEFAULT_ADMIN_ROLE`,
     * `MODULE_ADMIN_ROLE`, and `PAUSER_ROLE`.
     */
    function initializeDMRVManager(address _registryAddress, address _creditAddress) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());
        _grantRole(MODULE_ADMIN_ROLE, _msgSender());
        _grantRole(REVERSER_ROLE, _msgSender()); // Initially granted to deployer

        projectRegistry = IProjectRegistry(_registryAddress);
        creditContract = DynamicImpactCredit(_creditAddress);
    }

    /**
     * @notice Sets the address for the MethodologyRegistry.
     * @dev Can only be called once by an address with the `DEFAULT_ADMIN_ROLE`.
     * @param _methodologyRegistry The address of the deployed MethodologyRegistry contract.
     */
    function setMethodologyRegistry(address _methodologyRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_methodologyRegistry == address(0)) revert DMRVManager__ZeroAddress();
        methodologyRegistry = IMethodologyRegistry(_methodologyRegistry);
    }

    /**
     * @notice Initiates a verification request by delegating it to a registered verifier module.
     * @dev The project must be in the `Active` state. The specified `moduleType` must correspond
     * to a registered and trusted verifier module contract.
     * @param projectId The unique identifier of the project to verify.
     * @param claimId A unique identifier for the specific claim being verified.
     * @param evidenceURI A URI pointing to off-chain evidence related to the claim.
     * @param amount The number of impact credits being requested for this claim.
     * @param moduleType The type of verification module to use (e.g., "REPUTATION_WEIGHTED_V1").
     * @return taskId A unique ID for the task, returned from the verifier module.
     */
    function requestVerification(
        bytes32 projectId,
        bytes32 claimId,
        string calldata evidenceURI,
        uint256 amount,
        bytes32 moduleType
    ) external nonReentrant whenNotPaused returns (bytes32 taskId) {
        if (!projectRegistry.isProjectActive(projectId)) revert DMRVManager__ProjectNotActive();

        address moduleAddress = verifierModules[moduleType];
        if (moduleAddress == address(0)) revert DMRVManager__ModuleNotRegistered();

        _claimToModuleType[claimId] = moduleType;
        verifications[claimId] = Verification({projectId: projectId, evidenceURI: evidenceURI, amount: amount});

        emit VerificationDelegated(claimId, projectId, moduleType, moduleAddress, amount);

        taskId = IVerifierModule(moduleAddress).startVerificationTask(projectId, claimId, evidenceURI);
    }

    /**
     * @notice Callback function for registered verifier modules to deliver a final, trusted result.
     * @dev This is a privileged function that can only be called by the specific verifier module that
     * was assigned to handle the claim. It processes the incoming data to mint new impact credit tokens
     * or update the credential CID of existing ones.
     * @param projectId The ID of the project associated with the claim.
     * @param claimId The ID of the verification claim being fulfilled.
     * @param data The raw, encoded verification data from the module.
     */
    function fulfillVerification(bytes32 projectId, bytes32 claimId, bytes calldata data) external whenNotPaused {
        bytes32 moduleType = _claimToModuleType[claimId];
        if (moduleType == bytes32(0)) revert DMRVManager__ClaimNotFoundOrAlreadyFulfilled();
        if (verifications[claimId].amount == 0) revert DMRVManager__ClaimNotFoundOrAlreadyFulfilled();

        address expectedModule = verifierModules[moduleType];

        if (expectedModule == address(0)) revert DMRVManager__ModuleNotRegistered();
        if (msg.sender != expectedModule) revert DMRVManager__CallerNotRegisteredModule();

        // Process the verification data
        VerificationData memory vData = parseVerificationData(data);
        if (vData.quantitativeOutcome > 100) revert DMRVManager__InvalidQuantitativeOutcome();

        // Retrieve the original request
        Verification memory request = verifications[claimId];

        // Clean up state BEFORE processing to prevent re-fulfillment (checks-effects-interactions)
        delete _claimToModuleType[claimId];
        delete verifications[claimId];

        // Calculate the proportional amount of credits to mint
        uint256 amountToMint = (request.amount * vData.quantitativeOutcome) / 100;

        // Act based on the verification data
        processVerification(projectId, claimId, amountToMint, vData);

        emit VerificationFulfilled(claimId, projectId, moduleType, vData.quantitativeOutcome, amountToMint);
    }

    /**
     * @dev Internal function to process verified dMRV data. It mints new
     * credits to the project owner.
     * @param projectId The project identifier.
     * @param claimId The unique ID for the claim, used to record fulfillment data for potential reversals.
     * @param amountToMint The calculated number of credits to mint.
     * @param vData The parsed verification data containing the outcome and metadata.
     */
    function processVerification(
        bytes32 projectId,
        bytes32 claimId,
        uint256 amountToMint,
        VerificationData memory vData
    ) internal {
        if (amountToMint > 0) {
            // Get project owner from registry to mint credits to them
            try projectRegistry.getProject(projectId) returns (IProjectRegistry.Project memory project) {
                creditContract.mintCredits(project.owner, projectId, amountToMint, vData.credentialCID);

                // Store fulfillment data for potential reversal
                fulfillmentRecords[claimId] = FulfillmentRecord({
                    recipient: project.owner,
                    creditAmount: amountToMint,
                    quantitativeOutcome: vData.quantitativeOutcome
                });

                emit CreditsMinted(projectId, project.owner, amountToMint);
            } catch {
                emit MissingProjectError(projectId);
            }
        }
    }

    /**
     * @notice Returns the module type handling a specific claim.
     * @param claimId The ID of the claim.
     */
    function getModuleForClaim(bytes32 claimId) external view returns (bytes32) {
        return _claimToModuleType[claimId];
    }

    /**
     * @dev Parses the raw bytes data from a verifier module into a structured format.
     * This is the central point for adapting different module outputs into a standard internal format.
     * @param data The raw data from the module.
     * @return A `VerificationData` struct.
     */
    function parseVerificationData(bytes calldata data) internal pure returns (VerificationData memory) {
        // Current format from ReputationWeightedVerifier: (uint256 finalAmount, bool wasArbitrated, bytes32 disputeId, string evidenceURI)
        (uint256 quantitativeOutcome, bool wasArbitrated, bytes32 arbitrationDisputeId, string memory credentialCID) =
            abi.decode(data, (uint256, bool, bytes32, string));

        return VerificationData({
            quantitativeOutcome: quantitativeOutcome,
            wasArbitrated: wasArbitrated,
            arbitrationDisputeId: arbitrationDisputeId,
            credentialCID: credentialCID
        });
    }

    /**
     * @notice Admin function to manually submit verification data, bypassing the oracle.
     * @dev This is a privileged function for `DEFAULT_ADMIN_ROLE` holders. It is intended for
     * testing, emergency interventions, or manual data entry. It directly calls the internal
     * processing logic. Emits an `AdminVerificationSubmitted` event.
     * @param projectId The project identifier.
     * @param creditAmount Amount of credits to mint (can be 0).
     * @param credentialCID The new credential CID to set.
     * @param updateMetadataOnly If true, only updates metadata without minting.
     */
    function adminSubmitVerification(
        bytes32 projectId,
        uint256 creditAmount,
        string calldata credentialCID,
        bool updateMetadataOnly
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (!projectRegistry.isProjectActive(projectId)) revert DMRVManager__ProjectNotActive();

        VerificationData memory vData = VerificationData({
            quantitativeOutcome: 0, // Not needed for admin functions
            wasArbitrated: false,
            arbitrationDisputeId: bytes32(0), // Not needed for admin functions
            credentialCID: credentialCID
        });

        // Admin submissions are not reversible as they don't have a standard claimId.
        processVerification(projectId, bytes32(0), creditAmount, vData);
        emit AdminVerificationSubmitted(projectId, creditAmount, credentialCID, updateMetadataOnly);
    }

    /**
     * @notice Registers a verifier module that has been approved in the MethodologyRegistry.
     * @dev The caller must have the `MODULE_ADMIN_ROLE`. This function enforces that only
     * methodologies that are valid (approved and not deprecated) in the `MethodologyRegistry`
     * can be registered. This is a critical security gate.
     * @param moduleType The unique identifier for the methodology (e.g., "REPUTATION_WEIGHTED_V1").
     * @param moduleAddress The deployed address of the verifier module contract.
     */
    function registerVerifierModule(bytes32 moduleType, address moduleAddress) external onlyRole(MODULE_ADMIN_ROLE) {
        if (moduleAddress == address(0)) revert DMRVManager__ZeroAddress();
        if (methodologyRegistry == IMethodologyRegistry(address(0))) revert DMRVManager__RegistryNotSet();
        if (!methodologyRegistry.isMethodologyValid(moduleType)) revert DMRVManager__MethodologyNotValid();

        if (verifierModules[moduleType] != address(0)) revert DMRVManager__ModuleAlreadyRegistered(moduleType);

        verifierModules[moduleType] = moduleAddress;
        emit VerifierModuleRegistered(moduleType, moduleAddress);
    }

    /**
     * @notice Removes a verifier module from the manager.
     * @dev The caller must have the `MODULE_ADMIN_ROLE`. This prevents the module
     * from being used for any new verification requests.
     * @param moduleType The unique identifier for the module to remove.
     */
    function removeVerifierModule(bytes32 moduleType) external onlyRole(MODULE_ADMIN_ROLE) {
        if (verifierModules[moduleType] == address(0)) revert DMRVManager__ModuleNotRegistered();

        delete verifierModules[moduleType];
        emit VerifierModuleRemoved(moduleType);
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

    /**
     * @notice Reverses a fulfillment after a successful challenge.
     * @dev This is a privileged function that can only be called by a contract with the `REVERSER_ROLE`.
     * It burns any erroneously minted credits based on the fulfillment record.
     * @param projectId The ID of the project associated with the claim (unused but kept for interface compatibility).
     * @param claimId The ID of the verification claim being reversed.
     */
    function reverseFulfillment(bytes32 projectId, bytes32 claimId) external onlyRole(REVERSER_ROLE) {
        // Silence unused parameter warning
        projectId;

        FulfillmentRecord memory record = fulfillmentRecords[claimId];
        if (record.recipient == address(0) || record.creditAmount == 0) {
            revert DMRVManager__NothingToReverse();
        }

        // Delete the record first to prevent re-entrancy.
        delete fulfillmentRecords[claimId];

        creditContract.burnCredits(record.recipient, claimId, record.creditAmount);

        emit CreditsReversed(claimId, record.recipient, record.creditAmount);
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Gets all the roles held by a specific account.
     * @dev Provides an easy way for UIs and other tools to check permissions.
     * @param account The address to check.
     * @return A list of role identifiers held by the account.
     */
    function getRoles(address account) external view returns (bytes32[] memory) {
        bytes32[] memory allRoles = new bytes32[](3);
        allRoles[0] = DEFAULT_ADMIN_ROLE;
        allRoles[1] = PAUSER_ROLE;
        allRoles[2] = MODULE_ADMIN_ROLE;

        uint256 rolesLength = allRoles.length;
        uint256 count = 0;
        for (uint256 i = 0; i < rolesLength; i++) {
            if (hasRole(allRoles[i], account)) {
                count++;
            }
        }

        if (count == 0) {
            return new bytes32[](0);
        }

        bytes32[] memory roles = new bytes32[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < rolesLength; i++) {
            if (hasRole(allRoles[i], account)) {
                roles[index++] = allRoles[i];
                // Optimization: stop looping once all roles have been found.
                if (index == count) break;
            }
        }
        return roles;
    }
}
