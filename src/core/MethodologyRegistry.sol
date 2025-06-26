// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// --- Custom Errors ---
error MethodologyRegistry__MethodologyAlreadyExists();
error MethodologyRegistry__MethodologyNotFound();
error MethodologyRegistry__CallerNotAdmin();
error MethodologyRegistry__AlreadyApproved();

/**
 * @title MethodologyRegistry
 * @author Genci Mehmeti
 * @dev Serves as the single source of truth for all approved dMRV verification methodologies.
 * This contract is a critical security gate, ensuring that only DAO-vetted verifier modules
 * can be registered in the dMRVManager. It is owned and managed by the DAO's TimelockController.
 */
contract MethodologyRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // --- Roles ---
    bytes32 public constant METHODOLOGY_ADMIN_ROLE = keccak256("METHODOLOGY_ADMIN_ROLE");
    bytes32 public constant DEPRECATION_ROLE = keccak256("DEPRECATION_ROLE");

    // --- Data Structures ---
    struct Methodology {
        bytes32 methodologyId;
        address moduleImplementationAddress;
        string methodologySchemaURI; // IPFS CID of the full methodology document
        bytes32 schemaHash; // keccak256 hash of the document for integrity
        uint256 version;
        bool isApproved;
        bool isDeprecated;
    }

    // --- State ---
    mapping(bytes32 => Methodology) public methodologies;
    bytes32[] public methodologyIds;

    uint256[49] private __gap;

    // --- Events ---
    event MethodologyAdded(bytes32 indexed methodologyId, address indexed moduleImplementationAddress, uint256 version);
    event MethodologyApproved(bytes32 indexed methodologyId);
    event MethodologyDeprecated(bytes32 indexed methodologyId, bool isDeprecated);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract, setting up roles.
     * @dev The deployer is granted admin roles.
     * @param initialAdmin The address for the DEFAULT_ADMIN_ROLE, typically the Timelock.
     */
    function initialize(address initialAdmin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(METHODOLOGY_ADMIN_ROLE, initialAdmin);
        _grantRole(DEPRECATION_ROLE, initialAdmin);
    }

    /**
     * @notice Adds a new verification methodology to the registry.
     * @dev It is added in an unapproved state and must be approved via DAO governance.
     * Can only be called by an address with METHODOLOGY_ADMIN_ROLE.
     * @param methodologyId A unique ID for the methodology (e.g., keccak256("DEPIN_SOLAR_V1")).
     * @param moduleImplementationAddress The audited and deployed address of the verifier module.
     * @param methodologySchemaURI The IPFS CID pointing to the detailed methodology document.
     * @param schemaHash The keccak256 hash of the off-chain methodology document for integrity.
     */
    function addMethodology(
        bytes32 methodologyId,
        address moduleImplementationAddress,
        string calldata methodologySchemaURI,
        bytes32 schemaHash
    ) external onlyRole(METHODOLOGY_ADMIN_ROLE) {
        if (methodologies[methodologyId].moduleImplementationAddress != address(0)) {
            revert MethodologyRegistry__MethodologyAlreadyExists();
        }

        methodologies[methodologyId] = Methodology({
            methodologyId: methodologyId,
            moduleImplementationAddress: moduleImplementationAddress,
            methodologySchemaURI: methodologySchemaURI,
            schemaHash: schemaHash,
            version: 1, // First version
            isApproved: false, // Must be approved by DAO vote
            isDeprecated: false
        });
        methodologyIds.push(methodologyId);

        emit MethodologyAdded(methodologyId, moduleImplementationAddress, 1);
    }

    /**
     * @notice Approves a methodology, making it eligible for use in the dMRVManager.
     * @dev This is a highly privileged function intended to be called by the DAO's Timelock
     * after a successful governance vote. Can only be called by DEFAULT_ADMIN_ROLE.
     * @param methodologyId The ID of the methodology to approve.
     */
    function approveMethodology(bytes32 methodologyId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Methodology storage methodology = methodologies[methodologyId];
        if (methodology.moduleImplementationAddress == address(0)) revert MethodologyRegistry__MethodologyNotFound();
        if (methodology.isApproved) revert MethodologyRegistry__AlreadyApproved();

        methodology.isApproved = true;
        emit MethodologyApproved(methodologyId);
    }

    /**
     * @notice Toggles the deprecation status of a methodology.
     * @dev A deprecated module cannot be used for new verification tasks. This serves as a
     * rapid-response mechanism in case a vulnerability is found.
     * Can only be called by an address with DEPRECATION_ROLE.
     * @param methodologyId The ID of the methodology to deprecate or un-deprecate.
     * @param isDeprecated The new deprecation status.
     */
    function setDeprecationStatus(bytes32 methodologyId, bool isDeprecated) external onlyRole(DEPRECATION_ROLE) {
        Methodology storage methodology = methodologies[methodologyId];
        if (methodology.moduleImplementationAddress == address(0)) revert MethodologyRegistry__MethodologyNotFound();

        methodology.isDeprecated = isDeprecated;
        emit MethodologyDeprecated(methodologyId, isDeprecated);
    }

    /**
     * @notice A view function to check if a module is valid for registration.
     * @dev The dMRVManager will call this function.
     * @param methodologyId The ID to check.
     * @return A boolean indicating if the methodology is approved and not deprecated.
     */
    function isMethodologyValid(bytes32 methodologyId) external view returns (bool) {
        Methodology storage methodology = methodologies[methodologyId];
        return methodology.isApproved && !methodology.isDeprecated;
    }

    /**
     * @notice Returns the number of methodologies in the registry.
     */
    function getMethodologyCount() external view returns (uint256) {
        return methodologyIds.length;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
