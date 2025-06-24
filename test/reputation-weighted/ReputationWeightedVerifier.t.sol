// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    ReputationWeightedVerifier,
    ReputationWeightedVerifier__NotActiveVerifier,
    ReputationWeightedVerifier__TaskNotFound,
    ReputationWeightedVerifier__VotingPeriodOver,
    ReputationWeightedVerifier__TaskAlreadyResolved,
    ReputationWeightedVerifier__VotingPeriodNotOver
} from "../../src/reputation-weighted/ReputationWeightedVerifier.sol";
import {IVerifierManager} from "../../src/reputation-weighted/VerifierManager.sol";
import {MockReputationManager} from "../mocks/MockReputationManager.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

// --- Mocks for Testing ---

contract MockVerifierManager is IVerifierManager {
    mapping(address => bool) public verifierStatus;

    function isVerifier(address account) external view override returns (bool) {
        return verifierStatus[account];
    }

    function setVerifier(address account, bool status) public {
        verifierStatus[account] = status;
    }

    // Unused functions for this test
    function getVerifierStake(address) external view override returns (uint256) {
        return 0;
    }

    function slash(address, uint256, uint256) external override {}
}

contract MockDMRVManager {
    // This function exists so that the `expectCall` has a valid contract function to check against.
    function fulfillVerification(bytes32, bytes32, bytes calldata) external {}
}

contract ReputationWeightedVerifierTest is Test {
    // --- Constants ---
    uint256 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant APPROVAL_THRESHOLD_BPS = 5001; // 50.01%

    // --- State ---
    ReputationWeightedVerifier internal verifierModule;
    MockVerifierManager internal verifierManager;
    MockReputationManager internal reputationManager;
    address internal dMRVManagerAddress; // This will now be a contract address

    // --- Users ---
    address internal admin;
    address internal verifier1;
    address internal verifier2;
    address internal verifier3;
    address internal nonVerifier;

    function setUp() public {
        admin = makeAddr("admin");
        verifier1 = makeAddr("verifier1");
        verifier2 = makeAddr("verifier2");
        verifier3 = makeAddr("verifier3");
        nonVerifier = makeAddr("nonVerifier");

        // Deploy mocks
        verifierManager = new MockVerifierManager();
        reputationManager = new MockReputationManager();
        dMRVManagerAddress = address(new MockDMRVManager());

        // Deploy implementation and proxy
        vm.startPrank(admin);
        ReputationWeightedVerifier implementation = new ReputationWeightedVerifier();
        bytes memory initData = abi.encodeWithSelector(
            ReputationWeightedVerifier.initialize.selector,
            admin,
            address(verifierManager),
            address(reputationManager),
            dMRVManagerAddress,
            VOTING_PERIOD,
            APPROVAL_THRESHOLD_BPS
        );
        verifierModule = ReputationWeightedVerifier(address(new ERC1967Proxy(address(implementation), initData)));
        vm.stopPrank();

        // Setup verifier states
        verifierManager.setVerifier(verifier1, true);
        reputationManager.setReputation(verifier1, 100);

        verifierManager.setVerifier(verifier2, true);
        reputationManager.setReputation(verifier2, 75);

        verifierManager.setVerifier(verifier3, true);
        reputationManager.setReputation(verifier3, 50);
    }

    // --- Test startVerificationTask ---

    function test_startVerificationTask_succeeds() public {
        bytes32 projectId = keccak256("project1");
        bytes32 claimId = keccak256("claim1");
        string memory evidenceURI = "ipfs://evidence";

        vm.prank(dMRVManagerAddress);
        bytes32 taskId = verifierModule.startVerificationTask(projectId, claimId, evidenceURI);

        (bytes32 pId, bytes32 cId, string memory uri, uint64 deadline,,,) = verifierModule.tasks(taskId);
        assertEq(pId, projectId, "Project ID mismatch");
        assertEq(cId, claimId, "Claim ID mismatch");
        assertEq(uri, evidenceURI, "Evidence URI mismatch");
        assertEq(deadline, block.timestamp + VOTING_PERIOD, "Deadline mismatch");
    }

    function test_startVerificationTask_reverts_ifNotDMRVManager() public {
        vm.prank(nonVerifier);
        vm.expectRevert("Only dMRVManager can start tasks");
        verifierModule.startVerificationTask(bytes32(0), bytes32(0), "");
    }

    // --- Test submitVote ---

    function test_submitVote_succeeds() public {
        // Start a task
        vm.prank(dMRVManagerAddress);
        bytes32 taskId = verifierModule.startVerificationTask(bytes32(0), bytes32(0), "");

        // Verifier 1 approves
        vm.startPrank(verifier1);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.stopPrank();

        // Verifier 2 rejects
        vm.startPrank(verifier2);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject);
        vm.stopPrank();

        (uint256 weightedApprove, uint256 weightedReject) = verifierModule.getTaskVotes(taskId);
        assertEq(weightedApprove, 100, "Approve votes incorrect");
        assertEq(weightedReject, 75, "Reject votes incorrect");
    }

    function test_submitVote_reverts_ifNotActiveVerifier() public {
        vm.prank(dMRVManagerAddress);
        bytes32 taskId = verifierModule.startVerificationTask(bytes32(0), bytes32(0), "");

        vm.prank(nonVerifier);
        vm.expectRevert(ReputationWeightedVerifier__NotActiveVerifier.selector);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
    }

    // --- Test resolveTask ---

    function test_resolveTask_succeeds_withApproval() public {
        // 1. Start task
        vm.prank(dMRVManagerAddress);
        bytes32 projectId = keccak256("project_approve");
        bytes32 claimId = keccak256("claim_approve");
        bytes32 taskId = verifierModule.startVerificationTask(projectId, claimId, "");

        // 2. Votes (100 approve vs 75 reject)
        vm.prank(verifier1);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.prank(verifier2);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject);

        // 3. Fast-forward time
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // 4. Expect call to dMRVManager and resolve
        bytes memory expectedData = abi.encode(uint256(1), false, bytes32(0), "ipfs://verified");
        vm.expectCall(
            dMRVManagerAddress,
            abi.encodeWithSelector(DMRVManager.fulfillVerification.selector, projectId, claimId, expectedData)
        );
        verifierModule.resolveTask(taskId);

        (,,,, bool resolved,,) = verifierModule.tasks(taskId);
        assertTrue(resolved, "Task should be resolved");
    }

    function test_resolveTask_succeeds_withRejection() public {
        // 1. Start task
        vm.prank(dMRVManagerAddress);
        bytes32 projectId = keccak256("project_reject");
        bytes32 claimId = keccak256("claim_reject");
        bytes32 taskId = verifierModule.startVerificationTask(projectId, claimId, "");

        // 2. Votes (50 approve vs 175 reject)
        vm.prank(verifier3);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.prank(verifier1);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject);
        vm.prank(verifier2);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject);

        // 3. Fast-forward time
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // 4. Expect call to dMRVManager and resolve
        bytes memory expectedData = abi.encode(uint256(0), true, bytes32(0), "ipfs://rejected");
        vm.expectCall(
            dMRVManagerAddress,
            abi.encodeWithSelector(DMRVManager.fulfillVerification.selector, projectId, claimId, expectedData)
        );
        verifierModule.resolveTask(taskId);
    }

    function test_resolveTask_reverts_ifVotingPeriodNotOver() public {
        vm.prank(dMRVManagerAddress);
        bytes32 taskId = verifierModule.startVerificationTask(bytes32(0), bytes32(0), "");

        vm.expectRevert(ReputationWeightedVerifier__VotingPeriodNotOver.selector);
        verifierModule.resolveTask(taskId);
    }
}
