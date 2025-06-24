// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IProjectRegistry
 * @dev Interface for the ProjectRegistry contract.
 * Allows other contracts to securely interact with the registry to verify project status.
 */
interface IProjectRegistry {
    // --- Enums ---
    enum ProjectStatus {
        Pending,
        Active,
        Paused,
        Archived
    }

    // --- Structs ---
    struct Project {
        bytes32 id;
        string metaURI;
        address owner;
        ProjectStatus status;
    }

    // --- Functions ---
    function isProjectActive(bytes32 projectId) external view returns (bool);
    function getProject(bytes32 projectId) external view returns (Project memory);
    function setProjectStatus(bytes32 projectId, ProjectStatus newStatus) external;
}
