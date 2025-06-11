// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title IProjectRegistry
 * @dev Interface for the ProjectRegistry contract.
 * Allows other contracts to securely interact with the registry to verify project status.
 */
interface IProjectRegistry {
    function isProjectActive(bytes32 projectId) external view returns (bool);
}

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
    ReentrancyGuardUpgradeable
{
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    enum ProjectStatus {
        Pending, // Newly registered, awaiting verification
        Active,  // Verified and eligible for credit minting
        Paused,  // Temporarily suspended by admin
        Archived // Permanently archived, not active
    }

    struct Project {
        bytes32 id;
        address owner;
        ProjectStatus status;
        string metaURI; // URI to off-chain JSON metadata (IPFS)
    }

    mapping(bytes32 => Project) private _projects;

    // --- Events ---

    event ProjectRegistered(
        bytes32 indexed projectId,
        address indexed owner,
        string metaURI
    );
    event ProjectStatusChanged(
        bytes32 indexed projectId,
        ProjectStatus oldStatus,
        ProjectStatus newStatus
    );
    event ProjectMetaURIUpdated(bytes32 indexed projectId, string newMetaURI);
    event ProjectOwnershipTransferred(
        bytes32 indexed projectId,
        address indexed oldOwner,
        address indexed newOwner
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(VERIFIER_ROLE, _msgSender());
    }

    // --- State-Changing Functions ---

    /**
     * @notice Registers a new project. Anyone can register.
     * @dev The caller becomes the initial owner of the project. The project starts
     * in 'Pending' status and must be approved by a VERIFIER.
     * The projectId must be unique, typically a keccak256 hash of project details.
     * @param projectId The unique identifier for the project.
     * @param metaURI A URI pointing to an off-chain JSON file with project details.
     */
    function registerProject(bytes32 projectId, string calldata metaURI)
        external
        nonReentrant
    {
        require(
            _projects[projectId].id == 0,
            "ProjectRegistry: ID already exists"
        );

        _projects[projectId] = Project({
            id: projectId,
            owner: _msgSender(),
            status: ProjectStatus.Pending,
            metaURI: metaURI
        });

        emit ProjectRegistered(projectId, _msgSender(), metaURI);
    }

    /**
     * @notice Updates the status of an existing project.
     * @dev - VERIFIER_ROLE can move a project to 'Active'.
     *      - DEFAULT_ADMIN_ROLE can 'Pause' or 'Archive' a project for risk management.
     * @param projectId The ID of the project to update.
     * @param newStatus The new status for the project.
     */
    function setProjectStatus(bytes32 projectId, ProjectStatus newStatus)
        external
        nonReentrant
    {
        Project storage project = _projects[projectId];
        require(project.id != 0, "ProjectRegistry: Project not found");

        if (newStatus == ProjectStatus.Active) {
            require(
                hasRole(VERIFIER_ROLE, _msgSender()),
                "ProjectRegistry: Caller is not a verifier"
            );
        } else if (
            newStatus == ProjectStatus.Paused || newStatus == ProjectStatus.Archived
        ) {
            require(
                hasRole(DEFAULT_ADMIN_ROLE, _msgSender()),
                "ProjectRegistry: Caller is not an admin"
            );
        } else {
            revert("ProjectRegistry: Invalid status transition");
        }

        emit ProjectStatusChanged(projectId, project.status, newStatus);
        project.status = newStatus;
    }

    /**
     * @notice Allows the project owner to update the metadata URI.
     * @param projectId The ID of the project to update.
     * @param newMetaURI The new metadata URI.
     */
    function setMetaURI(bytes32 projectId, string calldata newMetaURI)
        external
        nonReentrant
    {
        _checkProjectOwner(projectId);
        _projects[projectId].metaURI = newMetaURI;
        emit ProjectMetaURIUpdated(projectId, newMetaURI);
    }

    /**
     * @notice Allows the current project owner to transfer ownership to a new address.
     * @param projectId The ID of the project being transferred.
     * @param newOwner The address of the new owner.
     */
    function transferOwnership(bytes32 projectId, address newOwner)
        external
        nonReentrant
    {
        _checkProjectOwner(projectId);
        require(
            newOwner != address(0),
            "ProjectRegistry: New owner is the zero address"
        );

        address oldOwner = _projects[projectId].owner;
        _projects[projectId].owner = newOwner;
        emit ProjectOwnershipTransferred(projectId, oldOwner, newOwner);
    }

    // --- View Functions ---

    /**
     * @notice Retrieves the full data for a given project.
     * @param projectId The ID of the project.
     * @return A Project struct containing all project data.
     */
    function getProject(bytes32 projectId)
        external
        view
        returns (Project memory)
    {
        require(
            _projects[projectId].id != 0,
            "ProjectRegistry: Project not found"
        );
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

    // --- Internal & Auth Functions ---

    /**
     * @dev Reverts if the caller is not the owner of the specified project.
     */
    function _checkProjectOwner(bytes32 projectId) internal view {
        require(
            _projects[projectId].id != 0,
            "ProjectRegistry: Project not found"
        );
        require(
            _projects[projectId].owner == _msgSender(),
            "ProjectRegistry: Caller is not the project owner"
        );
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return
            interfaceId == type(IProjectRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }
} 