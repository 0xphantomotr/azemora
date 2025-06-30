// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../core/interfaces/IVerifierModule.sol";
import "./interfaces/IVerifierManager.sol";
import "../core/interfaces/IDMRVManager.sol";
import "../governance/interfaces/IArbitrationCouncil.sol";
import "./interfaces/IReputationWeightedVerifier.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

// --- Custom Errors ---
error ReputationWeightedVerifier__NotActiveVerifier();
error ReputationWeightedVerifier__TaskNotFound();
error ReputationWeightedVerifier__VotingPeriodOver();
error ReputationweightedVerifier__InvalidTaskStatus(bytes32 taskId, TaskStatus currentStatus);
error ReputationWeightedVerifier__VotingPeriodNotOver();
error ReputationWeightedVerifier__ZeroAddress();
error ReputationWeightedVerifier__VoteAlreadyCast();
error ReputationWeightedVerifier__ChallengePeriodNotOver();
error ReputationWeightedVerifier__ChallengePeriodOver();
error ReputationWeightedVerifier__NotProvisional();
error ReputationWeightedVerifier__AlreadyFinalized();

enum TaskStatus {
    Voting,
    Provisional,
    Challenged,
    Finalized,
    Overturned
}

enum Vote {
    None,
    Approve,
    Reject
}

/**
 * @title ReputationWeightedVerifier
 * @author Azemora DAO
 * @dev Gathers weighted votes from verifiers and proposes a resolution.
 * The proposed resolution enters a "challenge period". If unchallenged, it becomes final.
 * If challenged, resolution is delegated to the ArbitrationCouncil.
 */
contract ReputationWeightedVerifier is
    Initializable,
    AccessControlEnumerableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IVerifierModule,
    IReputationWeightedVerifier
{
    // --- Roles ---
    bytes32 public constant ARBITRATION_COUNCIL_ROLE = keccak256("ARBITRATION_COUNCIL_ROLE");

    // --- State ---
    struct VerificationTask {
        bytes32 projectId;
        bytes32 claimId;
        string evidenceURI;
        uint256 deadline;
        TaskStatus status;
        bool provisionalOutcome; // true for approve, false for reject
        uint256 challengeDeadline;
        uint256 weightedApproveVotes;
        uint256 weightedRejectVotes;
        mapping(address => Vote) votes;
    }

    IVerifierManager public verifierManager;
    IDMRVManager public dMRVManager;
    IArbitrationCouncil public arbitrationCouncil;

    uint256 public votingPeriod;
    uint256 public approvalThresholdBps; // Basis points required for approval (e.g., 5001 for >50%)
    uint256 public challengePeriod; // Duration of the challenge window

    mapping(bytes32 => VerificationTask) public tasks;
    mapping(bytes32 => address[]) public taskVoters;
    uint256 public taskCounter;

    uint256[42] private __gap;

    // --- Events ---
    event TaskCreated(bytes32 indexed taskId, bytes32 indexed projectId, string evidenceURI, uint256 deadline);
    event Voted(bytes32 indexed taskId, address indexed voter, Vote vote, uint256 weight);
    event TaskResolutionProposed(bytes32 indexed taskId, bool provisionalOutcome, uint256 challengeDeadline);
    event TaskChallenged(bytes32 indexed taskId, address indexed challenger);
    event TaskFinalized(bytes32 indexed taskId, bool finalOutcome);
    event TaskOverturned(bytes32 indexed taskId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address _verifierManager,
        address _dMRVManager,
        address _arbitrationCouncil,
        uint256 _votingPeriod,
        uint256 _challengePeriod,
        uint256 _approvalThresholdBps
    ) public initializer {
        __AccessControlEnumerable_init();
        __Ownable_init(admin);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ARBITRATION_COUNCIL_ROLE, _arbitrationCouncil);

        verifierManager = IVerifierManager(_verifierManager);
        dMRVManager = IDMRVManager(_dMRVManager);
        arbitrationCouncil = IArbitrationCouncil(_arbitrationCouncil);
        votingPeriod = _votingPeriod;
        challengePeriod = _challengePeriod;
        approvalThresholdBps = _approvalThresholdBps;
    }

    function startVerificationTask(bytes32 projectId, bytes32 claimId, string calldata evidenceURI)
        external
        override
        returns (bytes32 taskId)
    {
        // require(msg.sender == address(dMRVManager), "Only dMRVManager can start tasks");

        taskId = keccak256(abi.encodePacked(projectId, claimId, taskCounter));
        taskCounter++;

        VerificationTask storage task = tasks[taskId];
        task.projectId = projectId;
        task.claimId = claimId;
        task.evidenceURI = evidenceURI;
        task.deadline = block.timestamp + votingPeriod;
        task.status = TaskStatus.Voting;

        emit TaskCreated(taskId, projectId, evidenceURI, task.deadline);
    }

    function submitVote(bytes32 taskId, Vote vote) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        if (task.deadline == 0) revert ReputationWeightedVerifier__TaskNotFound();
        if (block.timestamp > task.deadline) revert ReputationWeightedVerifier__VotingPeriodOver();
        if (task.status != TaskStatus.Voting) revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        if (!verifierManager.isVerifier(msg.sender)) revert ReputationWeightedVerifier__NotActiveVerifier();
        if (task.votes[msg.sender] != Vote.None) revert ReputationWeightedVerifier__VoteAlreadyCast();

        taskVoters[taskId].push(msg.sender);
        // For simplicity, reputation is 1 for now. This will be replaced by a call to a reputation contract.
        uint256 weight = 1; // reputationManager.getReputation(msg.sender);
        task.votes[msg.sender] = vote;

        if (vote == Vote.Approve) {
            task.weightedApproveVotes += weight;
        } else {
            task.weightedRejectVotes += weight;
        }

        emit Voted(taskId, msg.sender, vote, weight);
    }

    function proposeTaskResolution(bytes32 taskId) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        if (task.deadline == 0) revert ReputationWeightedVerifier__TaskNotFound();
        if (block.timestamp <= task.deadline) revert ReputationWeightedVerifier__VotingPeriodNotOver();
        if (task.status != TaskStatus.Voting) revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);

        uint256 totalVotes = task.weightedApproveVotes + task.weightedRejectVotes;
        bool approved = (totalVotes > 0) && ((task.weightedApproveVotes * 10000) / totalVotes > approvalThresholdBps);

        task.provisionalOutcome = approved;
        task.status = TaskStatus.Provisional;
        task.challengeDeadline = block.timestamp + challengePeriod;

        emit TaskResolutionProposed(taskId, approved, task.challengeDeadline);
    }

    function challengeVerification(bytes32 taskId) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        if (task.status != TaskStatus.Provisional) revert ReputationWeightedVerifier__NotProvisional();
        if (block.timestamp > task.challengeDeadline) revert ReputationWeightedVerifier__ChallengePeriodOver();

        task.status = TaskStatus.Challenged;

        // This contract must be approved by the challenger to spend the stake.
        arbitrationCouncil.createDispute(taskId, msg.sender, address(this));

        emit TaskChallenged(taskId, msg.sender);
    }

    function finalizeVerification(bytes32 taskId) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        if (task.status != TaskStatus.Provisional) revert ReputationWeightedVerifier__NotProvisional();
        if (block.timestamp <= task.challengeDeadline) revert ReputationWeightedVerifier__ChallengePeriodNotOver();

        task.status = TaskStatus.Finalized;

        bytes memory data;
        if (task.provisionalOutcome) {
            // On approval, mint 1 credit. The evidence URI becomes the credential CID.
            data = abi.encode(1, false, bytes32(0), task.evidenceURI);
        } else {
            // On rejection, mint 0 credits, which effectively does nothing but records the event.
            data = abi.encode(0, false, bytes32(0), task.evidenceURI);
        }
        dMRVManager.fulfillVerification(task.projectId, task.claimId, data);

        emit TaskFinalized(taskId, task.provisionalOutcome);
    }

    function processArbitrationResult(bytes32 taskId, bool overturned) external override {
        require(msg.sender == address(arbitrationCouncil), "Only ArbitrationCouncil can call this");

        VerificationTask storage task = tasks[taskId];
        if (task.status != TaskStatus.Challenged) {
            revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        }

        if (overturned) {
            // The provisional outcome was WRONG. The challenge was successful.
            // There is no need to call dMRVManager to reverse, because nothing was ever fulfilled.
            // We just update our internal state and slash the voters who were incorrect.
            task.status = TaskStatus.Overturned;

            Vote incorrectVote = task.provisionalOutcome ? Vote.Approve : Vote.Reject;
            address[] memory voters = taskVoters[taskId];
            for (uint256 i = 0; i < voters.length; i++) {
                if (task.votes[voters[i]] == incorrectVote) {
                    verifierManager.slash(voters[i]);
                }
            }
            emit TaskOverturned(taskId);
        } else {
            // The provisional outcome was CORRECT. The challenge failed. Finalize it.
            task.status = TaskStatus.Finalized;
            bytes memory data;
            if (task.provisionalOutcome) {
                // Mint 1 credit (or the appropriate amount).
                data = abi.encode(1, false, bytes32(0), task.evidenceURI);
            } else {
                // Mint 0 credits.
                data = abi.encode(0, false, bytes32(0), task.evidenceURI);
            }
            dMRVManager.fulfillVerification(task.projectId, task.claimId, data);
            emit TaskFinalized(taskId, task.provisionalOutcome);
        }
    }

    function reverseVerification(bytes32 claimId) external override onlyRole(ARBITRATION_COUNCIL_ROLE) {
        // This function is deprecated in favor of processArbitrationResult.
        // It's kept for interface compatibility but should not be called in the new flow.
        revert("Deprecated function");
    }

    function getModuleName() external pure override returns (string memory) {
        return "ReputationWeightedVerifier_v2";
    }

    // --- View Functions ---

    /**
     * @notice Returns the current status of a verification task.
     * @param taskId The ID of the task to query.
     * @return The status enum of the task.
     */
    function getTaskStatus(bytes32 taskId) external view returns (TaskStatus) {
        return tasks[taskId].status;
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // --- Unused IVerifierModule function ---
    function delegateVerification(bytes32, bytes calldata, address) external pure override {
        revert("This module does not support delegation");
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IVerifierModule).interfaceId
            || interfaceId == type(IReputationWeightedVerifier).interfaceId || super.supportsInterface(interfaceId);
    }
}
