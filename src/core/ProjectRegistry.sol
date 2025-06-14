// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title IProjectRegistry
 * @dev Interface for the ProjectRegistry contract.
 * Allows other contracts to securely interact with the registry to verify project status.
 */
interface IProjectRegistry {
    function isProjectActive(bytes32 projectId) external view returns (bool);
}

// --- Custom Errors ---
error ProjectRegistry__IdAlreadyExists();
error ProjectRegistry__ProjectNotFound();
error ProjectRegistry__StatusIsSame();
error ProjectRegistry__ArchivedProjectCannotBeModified();
error ProjectRegistry__CallerNotVerifier();
error ProjectRegistry__InvalidActivationState();
error ProjectRegistry__CallerNotAdmin();
error ProjectRegistry__InvalidPauseState();
error ProjectRegistry__InvalidStatusTransition();
error ProjectRegistry__NotProjectOwner();
error ProjectRegistry__NewOwnerIsZeroAddress();

/**
 * @title ProjectRegistry
 * @author Genci Mehmeti
 * @dev Manages the registration and lifecycle of climate action projects.
 * This contract serves as the on-chain registry, ensuring that environmental assets
 * can only be minted for valid, recognized projects. It uses UUPS for upgradeability
 * and AccessControl for role-based permissions, allowing for permissionless registration
 * with a subsequent verification step.
 */
contract ProjectRegistry is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32[] private _roles;

    enum ProjectStatus {
        Pending, // Newly registered, awaiting verification
        Active, // Verified and eligible for credit minting
        Paused, // Temporarily suspended by admin
        Archived // Permanently archived, not active

    }

    struct Project {
        bytes32 id;
        string metaURI; // URI to off-chain JSON metadata (IPFS)
        // --- Packed for gas efficiency ---
        address owner; // 20 bytes
        ProjectStatus status; // 1 byte
    }

    mapping(bytes32 => Project) private _projects;

    uint256[50] private __gap;

    // --- Events ---

    event ProjectRegistered(bytes32 indexed projectId, address indexed owner, string metaURI);
    event ProjectStatusChanged(bytes32 indexed projectId, ProjectStatus oldStatus, ProjectStatus newStatus);
    event ProjectMetaURIUpdated(bytes32 indexed projectId, string newMetaURI);
    event ProjectOwnershipTransferred(bytes32 indexed projectId, address indexed oldOwner, address indexed newOwner);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract, setting up roles and pausable state.
     * @dev The deployer is granted the `DEFAULT_ADMIN_ROLE`, `VERIFIER_ROLE`, and `PAUSER_ROLE`.
     * This function should only be called once on the implementation contract, and it is automatically
     * called by the proxy constructor during deployment.
     */
    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(VERIFIER_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());

        _roles.push(DEFAULT_ADMIN_ROLE);
        _roles.push(VERIFIER_ROLE);
        _roles.push(PAUSER_ROLE);
    }

    // --- State-Changing Functions ---

    /**
     * @notice Registers a new project, making it known to the Azemora platform.
     * @dev Anyone can register a project. The caller becomes the initial owner. The project starts
     * in the `Pending` state and must be moved to `Active` by a `VERIFIER_ROLE` holder
     * before any actions can be taken on it. The `projectId` should be a unique identifier,
     * typically a keccak256 hash of key project details to prevent collisions.
     * @param projectId The unique identifier for the project.
     * @param metaURI A URI pointing to an off-chain JSON file (e.g., on IPFS) with project details.
     */
    function registerProject(bytes32 projectId, string calldata metaURI) external nonReentrant whenNotPaused {
        if (_projects[projectId].id != 0) revert ProjectRegistry__IdAlreadyExists();

        _projects[projectId] =
            Project({id: projectId, metaURI: metaURI, owner: _msgSender(), status: ProjectStatus.Pending});

        emit ProjectRegistered(projectId, _msgSender(), metaURI);
    }

    /**
     * @notice Updates the status of an existing project (e.g., to activate, pause, or archive it).
     * @dev This is a privileged action.
     * - A `VERIFIER_ROLE` holder can move a project to `Active`.
     * - A `DEFAULT_ADMIN_ROLE` holder can `Pause` or `Archive` a project.
     * Status transitions are restricted to logical paths (e.g., you cannot activate an archived project).
     * @param projectId The ID of the project to update.
     * @param newStatus The new status for the project.
     */
    function setProjectStatus(bytes32 projectId, ProjectStatus newStatus) external nonReentrant whenNotPaused {
        Project storage project = _projects[projectId];
        ProjectStatus oldStatus = project.status;

        if (project.id == 0) revert ProjectRegistry__ProjectNotFound();
        if (oldStatus == newStatus) revert ProjectRegistry__StatusIsSame();
        if (oldStatus == ProjectStatus.Archived) revert ProjectRegistry__ArchivedProjectCannotBeModified();

        if (newStatus == ProjectStatus.Active) {
            if (!hasRole(VERIFIER_ROLE, _msgSender())) revert ProjectRegistry__CallerNotVerifier();
            if (oldStatus != ProjectStatus.Pending && oldStatus != ProjectStatus.Paused) {
                revert ProjectRegistry__InvalidActivationState();
            }
        } else if (newStatus == ProjectStatus.Paused) {
            if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) revert ProjectRegistry__CallerNotAdmin();
            if (oldStatus != ProjectStatus.Active) revert ProjectRegistry__InvalidPauseState();
        } else if (newStatus == ProjectStatus.Archived) {
            if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) revert ProjectRegistry__CallerNotAdmin();
            // Any non-archived state can be archived. The initial checks are sufficient.
        } else {
            // This case should be unreachable if all statuses are handled above.
            // It prevents transitioning to an undefined status.
            revert ProjectRegistry__InvalidStatusTransition();
        }

        emit ProjectStatusChanged(projectId, oldStatus, newStatus);
        project.status = newStatus;
    }

    /**
     * @notice Allows the project owner to update the project's metadata URI.
     * @dev The caller must be the current owner of the project. The URI should point to a valid
     * JSON metadata file, typically hosted on a decentralized storage system like IPFS.
     * @param projectId The ID of the project to update.
     * @param newMetaURI The new metadata URI.
     */
    function setProjectMetaURI(bytes32 projectId, string calldata newMetaURI) external nonReentrant whenNotPaused {
        Project storage project = _getProjectAndCheckOwner(projectId);
        project.metaURI = newMetaURI;
        emit ProjectMetaURIUpdated(projectId, newMetaURI);
    }

    /**
     * @notice Allows the current project owner to transfer project ownership to a new address.
     * @dev The caller must be the current owner. Ownership cannot be transferred to the zero address.
     * The new owner will have the authority to update the project's metadata URI and perform other
     * owner-specific actions in the future.
     * @param projectId The ID of the project being transferred.
     * @param newOwner The address of the new owner.
     */
    function transferProjectOwnership(bytes32 projectId, address newOwner) external nonReentrant whenNotPaused {
        Project storage project = _getProjectAndCheckOwner(projectId);
        if (newOwner == address(0)) revert ProjectRegistry__NewOwnerIsZeroAddress();

        address oldOwner = project.owner;
        project.owner = newOwner;
        emit ProjectOwnershipTransferred(projectId, oldOwner, newOwner);
    }

    // --- View Functions ---

    /**
     * @notice Retrieves the full data for a given project.
     * @param projectId The ID of the project.
     * @return A Project struct containing all project data.
     */
    function getProject(bytes32 projectId) external view returns (Project memory) {
        if (_projects[projectId].id == 0) revert ProjectRegistry__ProjectNotFound();
        return _projects[projectId];
    }

    /**
     * @notice Checks if a project is currently active.
     * @dev This is the primary view function for other contracts (like the NFT contract)
     * to verify a project's eligibility for minting.
     * @param projectId The ID of the project to check.
     * @return True if the project's status is Active, false otherwise.
     */
    function isProjectActive(bytes32 projectId) public view returns (bool) {
        return _projects[projectId].status == ProjectStatus.Active;
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

    // --- Internal & Auth Functions ---

    /**
     * @dev Gets project from storage and reverts if the caller is not the owner.
     * @return project The project struct from storage.
     */
    function _getProjectAndCheckOwner(bytes32 projectId) internal view returns (Project storage) {
        Project storage project = _projects[projectId];
        if (project.id == 0) revert ProjectRegistry__ProjectNotFound();
        if (project.owner != _msgSender()) revert ProjectRegistry__NotProjectOwner();
        return project;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IProjectRegistry).interfaceId || super.supportsInterface(interfaceId);
    }
}
