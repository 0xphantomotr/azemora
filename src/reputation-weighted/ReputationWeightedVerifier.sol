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
error ReputationWeightedVerifier__NotPending();
error ReputationWeightedVerifier__AlreadyFinalized();

enum TaskStatus {
    Pending,
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
        uint256 deadline; // Note: This field is now deprecated but kept for storage layout compatibility.
        TaskStatus status;
        bool outcome;
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
    event TaskCreated(bytes32 indexed taskId, bytes32 indexed projectId, string evidenceURI, uint256 challengeDeadline);
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

    /**
     * @notice MODIFICATION: This function now implements the optimistic verification model.
     * It creates a task in a 'Pending' state, assuming a successful outcome unless challenged.
     */
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
        task.status = TaskStatus.Pending; // Task is now pending and open to challenges.
        task.outcome = true; // Assume a successful outcome optimistically.
        task.challengeDeadline = block.timestamp + challengePeriod;

        emit TaskCreated(taskId, projectId, evidenceURI, task.challengeDeadline);
    }

    /*  ----------- DEPRECATED VOTING LOGIC -----------
        The optimistic verification model bypasses the need for universal, active voting.
        These functions are preserved to potentially be repurposed for the dispute/arbitration
        phase in a future implementation but are not part of the core optimistic flow.
    */
    function submitVote(bytes32 taskId, Vote vote) external nonReentrant {
        revert("DEPRECATED");
    }

    function proposeTaskResolution(bytes32 taskId) external nonReentrant {
        revert("DEPRECATED");
    }

    function challengeVerification(bytes32 taskId) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        if (task.status != TaskStatus.Pending) revert ReputationWeightedVerifier__NotPending();
        if (block.timestamp > task.challengeDeadline) revert ReputationWeightedVerifier__ChallengePeriodOver();

        task.status = TaskStatus.Challenged;

        // This contract must be approved by the challenger to spend the stake.
        arbitrationCouncil.createDispute(taskId, msg.sender, address(this));

        emit TaskChallenged(taskId, msg.sender);
    }

    function finalizeVerification(bytes32 taskId) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        if (task.status != TaskStatus.Pending) revert ReputationWeightedVerifier__NotPending();
        if (block.timestamp <= task.challengeDeadline) revert ReputationWeightedVerifier__ChallengePeriodNotOver();

        task.status = TaskStatus.Finalized;

        bytes memory data;
        if (task.outcome) {
            // On approval, mint 1 credit. The evidence URI becomes the credential CID.
            data = abi.encode(1, false, bytes32(0), task.evidenceURI);
        } else {
            // On rejection, mint 0 credits, which effectively does nothing but records the event.
            data = abi.encode(0, false, bytes32(0), task.evidenceURI);
        }
        dMRVManager.fulfillVerification(task.projectId, task.claimId, data);

        emit TaskFinalized(taskId, task.outcome);
    }

    function processArbitrationResult(bytes32 taskId, uint256 finalAmount) external override {
        require(msg.sender == address(arbitrationCouncil), "Only ArbitrationCouncil can call this");

        VerificationTask storage task = tasks[taskId];
        if (task.status != TaskStatus.Challenged) {
            revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        }

        if (finalAmount > 0) {
            task.status = TaskStatus.Finalized;
            bytes memory data = abi.encode(finalAmount, false, bytes32(0), task.evidenceURI);
            dMRVManager.fulfillVerification(task.projectId, task.claimId, data);
            emit TaskFinalized(taskId, true); // True because some amount was approved.
        } else {
            // If the final amount is 0, the claim is fully overturned.
            task.status = TaskStatus.Overturned;
            emit TaskOverturned(taskId);
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
