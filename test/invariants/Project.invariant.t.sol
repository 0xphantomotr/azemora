// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Interface to break the circular dependency between the test and the handler.
interface IProjectStateCallback {
    function trackProjectCreation(bytes32 projectId) external;
    function trackStateChange(bytes32 projectId, ProjectRegistry.ProjectStatus newStatus) external;
}

/**
 * @title ProjectStateHandler
 * @notice The "fuzzer actor" that performs random actions on the ProjectRegistry.
 * @dev Foundry's fuzzer calls this handler's functions. The handler attempts
 *      valid and invalid state transitions. If a transition succeeds, it notifies
 *      the main test contract to update the ghost state variables.
 */
contract ProjectStateHandler is Test {
    IProjectStateCallback immutable mainTest;
    ProjectRegistry immutable registry;
    address immutable projectCreator;
    address immutable verifier;

    // Keep track of projects created by this handler to randomly interact with them.
    bytes32[] public projectIds;

    constructor(
        IProjectStateCallback _mainTest,
        ProjectRegistry _registry,
        address _projectCreator,
        address _verifier
    ) {
        mainTest = _mainTest;
        registry = _registry;
        projectCreator = _projectCreator;
        verifier = _verifier;
    }

    /// @notice FUZZ ACTION: Register a new project.
    function register() public {
        // Create a unique project ID for each registration attempt.
        bytes32 projectId = keccak256(abi.encodePacked("Project ", projectIds.length));
        vm.prank(projectCreator);

        // This call is not expected to revert under normal circumstances.
        try registry.registerProject(projectId, "ipfs://") {
            projectIds.push(projectId);
            mainTest.trackProjectCreation(projectId);
        } catch {}
    }

    /// @notice FUZZ ACTION: Attempt to change a project's status to a random new state.
    function setStatus(ProjectRegistry.ProjectStatus newStatus) public {
        if (projectIds.length == 0) return;

        // Pick a random project to try and change.
        uint256 projectIndex = block.timestamp % projectIds.length;
        bytes32 projectId = projectIds[projectIndex];

        // Randomly use the admin (projectCreator) or the verifier to attempt the state change.
        // This is crucial to test the role-based access control of setProjectStatus.
        address actor = (block.timestamp % 2 == 0) ? projectCreator : verifier;
        vm.prank(actor);

        // This call is EXPECTED to revert often, as the fuzzer will try invalid state transitions.
        // This is exactly what we want to test.
        try registry.setProjectStatus(projectId, newStatus) {
            // SUCCESS CASE: The state transition was valid. Notify the main test.
            mainTest.trackStateChange(projectId, newStatus);
        } catch {}
    }
}

/**
 * @title ProjectInvariantTest
 * @notice An invariant test to ensure the project lifecycle state machine is always respected.
 */
contract ProjectInvariantTest is Test, IProjectStateCallback {
    // Contracts
    ProjectRegistry registry;

    // Users
    address admin = makeAddr("admin");
    address projectCreator = makeAddr("projectCreator"); // Also has ADMIN_ROLE for this test
    address verifier = makeAddr("verifier");

    // The GHOST STATE: Tracks the current state of all projects created by the fuzzer.
    mapping(bytes32 => ProjectRegistry.ProjectStatus) public projectStates;

    function setUp() public {
        vm.startPrank(admin);
        registry = ProjectRegistry(address(new ERC1967Proxy(address(new ProjectRegistry()), "")));
        registry.initialize();
        // Grant the creator the admin role to allow pausing/archiving.
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), projectCreator);
        // Grant the verifier role.
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        vm.stopPrank();

        // --- Setup Handler ---
        ProjectStateHandler handler = new ProjectStateHandler(this, registry, projectCreator, verifier);
        // Tell the fuzzer to call functions on the handler.
        targetContract(address(handler));
    }

    // --- Callback Functions (called by handler) ---

    function trackProjectCreation(bytes32 projectId) external override {
        // New projects are created in the Pending state.
        projectStates[projectId] = ProjectRegistry.ProjectStatus.Pending;
    }

    /*
     * @notice INVARIANT: Asserts the correctness of the project state machine.
     * @dev This callback is invoked by the handler ONLY when a `setProjectStatus` call
     *      succeeds. It then checks if the transition from the old state to the new
     *      state was valid according to our defined state machine rules. If an invalid
     *      transition somehow succeeds on-chain, this assertion will fail, proving a
     *      vulnerability in the contract's state transition logic.
     */
    function trackStateChange(bytes32 projectId, ProjectRegistry.ProjectStatus newStatus) external override {
        ProjectRegistry.ProjectStatus oldStatus = projectStates[projectId];

        // State machine logic validation
        if (oldStatus == ProjectRegistry.ProjectStatus.Pending) {
            // From Pending, can only move to Active (verified) or Archived (rejected).
            bool isValid =
                newStatus == ProjectRegistry.ProjectStatus.Active || newStatus == ProjectRegistry.ProjectStatus.Archived;
            assertTrue(isValid, "INVALID_TRANSITION_FROM_PENDING");
        } else if (oldStatus == ProjectRegistry.ProjectStatus.Active) {
            // From Active, can only move to Paused or Archived.
            bool isValid =
                newStatus == ProjectRegistry.ProjectStatus.Paused || newStatus == ProjectRegistry.ProjectStatus.Archived;
            assertTrue(isValid, "INVALID_TRANSITION_FROM_ACTIVE");
        } else if (oldStatus == ProjectRegistry.ProjectStatus.Paused) {
            // From Paused, can move back to Active or be Archived.
            bool isValid =
                newStatus == ProjectRegistry.ProjectStatus.Active || newStatus == ProjectRegistry.ProjectStatus.Archived;
            assertTrue(isValid, "INVALID_TRANSITION_FROM_PAUSED");
        } else if (oldStatus == ProjectRegistry.ProjectStatus.Archived) {
            // Archived is a terminal state. No transitions out should be possible.
            // If the handler successfully makes a state change from Archived and calls this
            // function, this test should fail immediately.
            revert("VIOLATION: Project moved out of Archived state.");
        }

        // Update our tracked state.
        projectStates[projectId] = newStatus;
    }
}
