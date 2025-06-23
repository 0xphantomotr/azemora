// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../core/interfaces/IVerifierModule.sol";
import "../achievements/interfaces/IReputationManager.sol";
import "./VerifierManager.sol";
import "../core/dMRVManager.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

// --- Custom Errors ---
error ReputationWeightedVerifier__NotActiveVerifier();
error ReputationWeightedVerifier__TaskNotFound();
error ReputationWeightedVerifier__VotingPeriodOver();
error ReputationWightedVerifier__TaskAlreadyResolved();
error ReputationWeightedVerifier__VotingPeriodNotOver();
error ReputationWeightedVerifier__ZeroAddress();
error ReputationWeightedVerifier__VoteAlreadyCast();

/**
 * @title ReputationWeightedVerifier
 * @author Genci Mehmeti
 * @dev The core logic engine for reputation-weighted verification tasks.
 * It receives tasks from dMRVManager, gathers votes from verifiers registered
 * in the VerifierManager, calculates the weighted outcome based on reputation,
 * and reports the result back to the dMRVManager.
 */
contract ReputationWeightedVerifier is
    Initializable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IVerifierModule
{
    // --- State ---
    enum Vote {
        None, // 0
        Approve, // 1
        Reject // 2

    }

    struct VerificationTask {
        bytes32 projectId;
        bytes32 claimId;
        string evidenceURI;
        uint64 deadline;
        bool resolved;
        uint256 weightedApproveVotes;
        uint256 weightedRejectVotes;
        mapping(address => Vote) votes;
    }

    IVerifierManager public verifierManager;
    IReputationManager public reputationManager;
    address public dMRVManager;

    uint256 public votingPeriod; // Duration for voting on a task
    uint256 public approvalThresholdBps; // Basis points required for approval (e.g., 5001 for >50%)

    mapping(bytes32 => VerificationTask) public tasks;
    uint256 public taskCounter;

    uint256[50] private __gap;

    // --- Events ---
    event TaskCreated(bytes32 indexed taskId, bytes32 indexed projectId, string evidenceURI, uint256 deadline);
    event Voted(bytes32 indexed taskId, address indexed voter, Vote vote, uint256 weight);
    event TaskResolved(bytes32 indexed taskId, bool approved, uint256 approveVotes, uint256 rejectVotes);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address verifierManager_,
        address reputationManager_,
        address dMRVManager_,
        uint256 votingPeriod_,
        uint256 approvalThresholdBps_
    ) public initializer {
        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (verifierManager_ == address(0) || reputationManager_ == address(0) || dMRVManager_ == address(0)) {
            revert ReputationWeightedVerifier__ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        verifierManager = IVerifierManager(verifierManager_);
        reputationManager = IReputationManager(reputationManager_);
        dMRVManager = dMRVManager_;
        votingPeriod = votingPeriod_;
        approvalThresholdBps = approvalThresholdBps_;
    }

    // --- IVerifierModule Implementation ---

    function startVerificationTask(bytes32 projectId, bytes32 claimId, string calldata evidenceURI)
        external
        override
        returns (bytes32 taskId)
    {
        // Ensure this is only called by the dMRVManager
        require(msg.sender == dMRVManager, "Only dMRVManager can start tasks");

        taskId = keccak256(abi.encodePacked(projectId, claimId, taskCounter));
        taskCounter++;

        VerificationTask storage task = tasks[taskId];
        task.projectId = projectId;
        task.claimId = claimId;
        task.evidenceURI = evidenceURI;
        task.deadline = uint64(block.timestamp + votingPeriod);

        emit TaskCreated(taskId, projectId, evidenceURI, task.deadline);
        return taskId;
    }

    function delegateVerification(
        bytes32, /* claimId */
        bytes32, /* projectId */
        bytes calldata, /* data */
        address /* originalSender */
    ) external pure override {
        revert("ReputationWeightedVerifier: Delegation not supported");
    }

    // --- Verifier Functions ---

    function submitVote(bytes32 taskId, Vote vote) external nonReentrant {
        VerificationTask storage task = tasks[taskId];

        if (task.deadline == 0) revert ReputationWeightedVerifier__TaskNotFound();
        if (block.timestamp > task.deadline) revert ReputationWeightedVerifier__VotingPeriodOver();
        if (!verifierManager.isVerifier(msg.sender)) revert ReputationWeightedVerifier__NotActiveVerifier();
        if (task.votes[msg.sender] != Vote.None) revert ReputationWeightedVerifier__VoteAlreadyCast();

        uint256 weight = reputationManager.getReputation(msg.sender);
        task.votes[msg.sender] = vote;

        if (vote == Vote.Approve) {
            task.weightedApproveVotes += weight;
        } else if (vote == Vote.Reject) {
            task.weightedRejectVotes += weight;
        }

        emit Voted(taskId, msg.sender, vote, weight);
    }

    // --- Task Resolution ---

    function resolveTask(bytes32 taskId) external nonReentrant {
        VerificationTask storage task = tasks[taskId];

        if (task.deadline == 0) revert ReputationWeightedVerifier__TaskNotFound();
        if (block.timestamp <= task.deadline) revert ReputationWeightedVerifier__VotingPeriodNotOver();
        if (task.resolved) revert ReputationWightedVerifier__TaskAlreadyResolved();

        task.resolved = true;
        uint256 totalVotes = task.weightedApproveVotes + task.weightedRejectVotes;
        bool approved = false;

        if (totalVotes > 0) {
            // Check if approval votes meet the threshold
            if ((task.weightedApproveVotes * 10000) / totalVotes >= approvalThresholdBps) {
                approved = true;
            }
        }

        // Fulfill the verification in the dMRVManager
        // For now, we pass a simple "true" or "false" in the data bytes.
        // This can be expanded to include more details.
        bytes memory resultData = abi.encode(approved);
        DMRVManager(dMRVManager).fulfillVerification(task.projectId, task.claimId, resultData);

        emit TaskResolved(taskId, approved, task.weightedApproveVotes, task.weightedRejectVotes);
    }

    // --- View Functions & Admin ---

    function getTaskVotes(bytes32 taskId) external view returns (uint256, uint256) {
        return (tasks[taskId].weightedApproveVotes, tasks[taskId].weightedRejectVotes);
    }

    function getModuleName() external pure override returns (string memory) {
        return "ReputationWeightedVerifier_v1";
    }

    function owner() external view override returns (address) {
        // Assumes the first member of the admin role is the conceptual owner.
        return getRoleMember(DEFAULT_ADMIN_ROLE, 0);
    }

    function setApprovalThreshold(uint256 newThresholdBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        approvalThresholdBps = newThresholdBps;
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // --- Interface Support ---
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
