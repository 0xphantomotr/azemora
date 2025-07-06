// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/core/interfaces/IProjectRegistry.sol";

/**
 * @title MockProjectRegistry
 * @dev A mock implementation of the IProjectRegistry for testing purposes.
 * It allows tests to easily set project statuses without deploying the full-featured registry.
 */
contract MockProjectRegistry is IProjectRegistry {
    mapping(bytes32 => Project) private _projects;

    function isProjectActive(bytes32 projectId) external view override returns (bool) {
        return _projects[projectId].status == ProjectStatus.Active;
    }

    function getProject(bytes32 projectId) external view override returns (Project memory) {
        return _projects[projectId];
    }

    function setProjectStatus(bytes32 projectId, ProjectStatus newStatus) public override {
        _projects[projectId].status = newStatus;
    }

    // --- Test-specific helper functions ---

    function addProject(bytes32 projectId, address owner) public {
        _projects[projectId] =
            Project({id: projectId, metaURI: "ipfs://mock", owner: owner, status: ProjectStatus.Pending});
    }
}
