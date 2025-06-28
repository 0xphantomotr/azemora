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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";

enum TaskStatus {
    Idle,
    Voting,
    Provisional,
    Challenged,
    Resolved
}

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
error ReputationWeightedVerifier__InsufficientStakeAllowance();
error ReputationWeightedVerifier__NotOnCouncil();
error ReputationWeightedVerifier__ArbitrationVoteAlreadyCast();
error ReputationWeightedVerifier__ArbitrationPeriodNotOver();
error ReputationWeightedVerifier__RandomnessRequestFailed();
error ReputationWeightedVerifier__RequestIdNotFound();
error ReputationWeightedVerifier__NotEnoughVerifiers();

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
    // --- Structs for Initialization ---
    struct AddressesConfig {
        address verifierManager;
        address reputationManager;
        address dMRVManager;
        address treasury;
        address challengeToken;
        address vrfCoordinator;
    }

    struct TimingsConfig {
        uint256 votingPeriod;
        uint256 challengePeriod;
    }

    struct ParametersConfig {
        uint256 approvalThresholdBps;
        uint256 challengeStakeAmount;
        uint8 councilSize;
        uint256 incorrectVoteStakePenalty;
        uint256 incorrectVoteReputationPenalty;
        uint64 vrfSubscriptionId;
        bytes32 vrfKeyHash;
    }

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
        TaskStatus status;
        bool provisionalOutcome; // true for approve, false for reject
        uint64 challengeDeadline;
        uint256 weightedApproveVotes;
        uint256 weightedRejectVotes;
        mapping(address => Vote) votes;
        address[] voters;
    }

    struct Challenge {
        address challenger;
        string evidenceURI;
        uint256 stake;
        bool active;
        address[] councilMembers;
        mapping(address => bool) hasVotedOnChallenge;
        mapping(address => bool) councilVotes; // true for uphold, false for overturn
        uint256 upholdVotes; // Votes to uphold the original provisionalOutcome
        uint256 overturnVotes; // Votes to overturn the original provisionalOutcome
        uint64 challengeVoteDeadline;
        uint256 vrfRequestId;
    }

    IVerifierManager public verifierManager;
    IReputationManager public reputationManager;
    address public dMRVManager;
    address public treasury;
    IERC20 public challengeToken; // The token used for staking challenges (AZE)

    uint256 public votingPeriod; // Duration for voting on a task
    uint256 public approvalThresholdBps; // Basis points required for approval (e.g., 5001 for >50%)
    uint256 public challengePeriod; // Duration of the challenge window
    uint256 public challengeStakeAmount; // Amount of AZE required to stake a challenge
    uint8 public councilSize; // The number of members in an arbitration council
    uint256 public incorrectVoteStakePenalty; // Amount of stake slashed from an incorrect voter
    uint256 public incorrectVoteReputationPenalty; // Amount of reputation slashed from an incorrect voter

    VRFCoordinatorV2Interface public vrfCoordinator;
    uint64 public s_subscriptionId;
    bytes32 public s_keyHash; // The gas lane key hash
    uint32 public callbackGasLimit = 500000; // Gas limit for the callback function
    uint16 public requestConfirmations = 3; // Number of confirmations for VRF request

    mapping(bytes32 => VerificationTask) public tasks;
    mapping(bytes32 => Challenge) public challenges;
    mapping(uint256 => bytes32) public vrfRequestToTaskId;
    uint256 public taskCounter;

    uint256[42] private __gap;

    // --- Events ---
    event TaskCreated(bytes32 indexed taskId, bytes32 indexed projectId, string evidenceURI, uint256 deadline);
    event Voted(bytes32 indexed taskId, address indexed voter, Vote vote, uint256 weight);
    event TaskResolved(bytes32 indexed taskId, bool approved, uint256 approveVotes, uint256 rejectVotes);
    event TaskResolutionProposed(bytes32 indexed taskId, bool provisionalOutcome, uint256 challengeDeadline);
    event TaskChallenged(bytes32 indexed taskId, address indexed challenger, string evidenceURI);
    event ArbitrationVoteCast(bytes32 indexed taskId, address indexed councilMember, bool didUphold);
    event ChallengeResolved(bytes32 indexed taskId, bool wasUpheld);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyVRFCoordinator() {
        require(msg.sender == address(vrfCoordinator), "Only VRF coordinator can call this function");
        _;
    }

    function initialize(
        address admin_,
        AddressesConfig calldata addrs,
        TimingsConfig calldata timings,
        ParametersConfig calldata params
    ) public initializer {
        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (addrs.verifierManager == address(0)) revert ReputationWeightedVerifier__ZeroAddress();
        if (addrs.reputationManager == address(0)) revert ReputationWeightedVerifier__ZeroAddress();
        if (addrs.dMRVManager == address(0)) revert ReputationWeightedVerifier__ZeroAddress();
        if (addrs.challengeToken == address(0)) revert ReputationWeightedVerifier__ZeroAddress();
        if (addrs.treasury == address(0)) revert ReputationWeightedVerifier__ZeroAddress();
        if (addrs.vrfCoordinator == address(0)) revert ReputationWeightedVerifier__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        verifierManager = IVerifierManager(addrs.verifierManager);
        reputationManager = IReputationManager(addrs.reputationManager);
        dMRVManager = addrs.dMRVManager;
        treasury = addrs.treasury;
        challengeToken = IERC20(addrs.challengeToken);
        vrfCoordinator = VRFCoordinatorV2Interface(addrs.vrfCoordinator);

        votingPeriod = timings.votingPeriod;
        challengePeriod = timings.challengePeriod;

        approvalThresholdBps = params.approvalThresholdBps;
        challengeStakeAmount = params.challengeStakeAmount;
        councilSize = params.councilSize;
        incorrectVoteStakePenalty = params.incorrectVoteStakePenalty;
        incorrectVoteReputationPenalty = params.incorrectVoteReputationPenalty;
        s_subscriptionId = params.vrfSubscriptionId;
        s_keyHash = params.vrfKeyHash;
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
        task.status = TaskStatus.Voting;

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
        if (task.status != TaskStatus.Voting) {
            revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        }
        if (!verifierManager.isVerifier(msg.sender)) revert ReputationWeightedVerifier__NotActiveVerifier();
        if (task.votes[msg.sender] != Vote.None) revert ReputationWeightedVerifier__VoteAlreadyCast();

        task.voters.push(msg.sender);
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

    /**
     * @notice Resolves the voting period, calculating a provisional outcome and starting the challenge period.
     * @dev Can be called by anyone after the voting period is over.
     * @param taskId The ID of the task to resolve.
     */
    function proposeResolution(bytes32 taskId) external nonReentrant {
        VerificationTask storage task = tasks[taskId];

        if (task.deadline == 0) revert ReputationWeightedVerifier__TaskNotFound();
        if (block.timestamp <= task.deadline) revert ReputationWeightedVerifier__VotingPeriodNotOver();
        if (task.status != TaskStatus.Voting) {
            revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        }

        task.status = TaskStatus.Provisional;
        task.challengeDeadline = uint64(block.timestamp + challengePeriod);

        uint256 totalVotes = task.weightedApproveVotes + task.weightedRejectVotes;
        bool approved = false;

        if (totalVotes > 0) {
            if ((task.weightedApproveVotes * 10000) / totalVotes >= approvalThresholdBps) {
                approved = true;
            }
        }
        task.provisionalOutcome = approved;

        emit TaskResolutionProposed(taskId, approved, task.challengeDeadline);
    }

    /**
     * @notice Allows a user to challenge a provisional outcome by staking tokens.
     * @dev This moves the task into a 'Challenged' state, preventing finalization until
     * the challenge is resolved by an arbitration council.
     * @param taskId The ID of the task to challenge.
     * @param evidenceURI A URI pointing to evidence supporting the challenge.
     * @return requestId The ID of the VRF request.
     */
    function challengeResolution(bytes32 taskId, string calldata evidenceURI)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        VerificationTask storage task = tasks[taskId];

        if (task.status != TaskStatus.Provisional) {
            revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        }
        if (block.timestamp >= task.challengeDeadline) {
            revert ReputationWeightedVerifier__ChallengePeriodOver();
        }

        uint256 stakeAmount = challengeStakeAmount;
        if (challengeToken.allowance(msg.sender, address(this)) < stakeAmount) {
            revert ReputationWeightedVerifier__InsufficientStakeAllowance();
        }

        challengeToken.transferFrom(msg.sender, address(this), stakeAmount);

        task.status = TaskStatus.Challenged;
        Challenge storage challenge = challenges[taskId];
        challenge.challenger = msg.sender;
        challenge.evidenceURI = evidenceURI;
        challenge.stake = stakeAmount;
        challenge.active = true;

        // --- Request Randomness from Chainlink VRF ---
        requestId = vrfCoordinator.requestRandomWords(
            s_keyHash, s_subscriptionId, requestConfirmations, callbackGasLimit, councilSize
        );

        if (requestId == 0) revert ReputationWeightedVerifier__RandomnessRequestFailed();

        // --- Store the request ID ---
        vrfRequestToTaskId[requestId] = taskId;
        challenge.vrfRequestId = requestId; // Link challenge to VRF request

        emit TaskChallenged(taskId, msg.sender, evidenceURI);
    }

    /**
     * @notice Allows a member of the arbitration council to vote on a challenge.
     * @param taskId The ID of the task being challenged.
     * @param upholdOriginalDecision True to vote to uphold the original provisional outcome, false to overturn it.
     */
    function castArbitrationVote(bytes32 taskId, bool upholdOriginalDecision) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        Challenge storage challenge = challenges[taskId];

        if (task.status != TaskStatus.Challenged) {
            revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        }

        bool isCouncilMember = false;
        for (uint256 i = 0; i < challenge.councilMembers.length; i++) {
            if (challenge.councilMembers[i] == msg.sender) {
                isCouncilMember = true;
                break;
            }
        }
        if (!isCouncilMember) revert ReputationWeightedVerifier__NotOnCouncil();
        if (challenge.hasVotedOnChallenge[msg.sender]) revert ReputationWeightedVerifier__ArbitrationVoteAlreadyCast();

        challenge.hasVotedOnChallenge[msg.sender] = true;
        challenge.councilVotes[msg.sender] = upholdOriginalDecision;
        if (upholdOriginalDecision) {
            challenge.upholdVotes++;
        } else {
            challenge.overturnVotes++;
        }

        emit ArbitrationVoteCast(taskId, msg.sender, upholdOriginalDecision);
    }

    /**
     * @notice Resolves a challenge after the arbitration vote is complete.
     * @dev This function calculates the final outcome, slashes incorrect voters, rewards the
     * challenger if they were correct, and calls the dMRVManager if the final outcome is 'Approve'.
     * @param taskId The ID of the task to resolve the challenge for.
     * @param credentialCID The IPFS CID of the Verifiable Credential, provided if the final outcome is approval.
     */
    function resolveChallenge(bytes32 taskId, string calldata credentialCID) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        Challenge storage challenge = challenges[taskId];

        if (task.status != TaskStatus.Challenged) {
            revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        }

        if (
            block.timestamp < challenge.challengeVoteDeadline
                && (challenge.upholdVotes + challenge.overturnVotes < challenge.councilMembers.length)
        ) {
            revert ReputationWeightedVerifier__ArbitrationPeriodNotOver();
        }

        bool challengeUpheld = challenge.upholdVotes > challenge.overturnVotes;

        // --- Apply Penalties ---

        // 1. Penalize incorrect council members.
        address[] memory incorrectCouncilVoters;
        if (challengeUpheld) {
            // Council members who voted to OVERTURN were wrong.
            incorrectCouncilVoters = _getCouncilVotersByVote(challenge, false);
        } else {
            // Council members who voted to UPHOLD were wrong.
            incorrectCouncilVoters = _getCouncilVotersByVote(challenge, true);
        }
        if (incorrectCouncilVoters.length > 0) {
            _slashVerifiers(incorrectCouncilVoters, incorrectVoteStakePenalty, incorrectVoteReputationPenalty);
        }

        // 2. Penalize incorrect original voters ONLY IF the challenge was successful (outcome overturned).
        if (!challengeUpheld) {
            // Collect original voters who voted for the now-overturned provisional outcome.
            address[] memory allVoters = task.voters;
            address[] memory incorrectOriginalVoters = new address[](allVoters.length);
            uint256 incorrectCount = 0;

            for (uint256 i = 0; i < allVoters.length; i++) {
                address voter = allVoters[i];
                Vote voterVote = task.votes[voter]; // Approve (1) or Reject (2)
                bool voterApproved = voterVote == Vote.Approve;

                // If voter's decision matched the (wrong) provisional outcome, they were incorrect.
                if (voterApproved == task.provisionalOutcome) {
                    incorrectOriginalVoters[incorrectCount++] = voter;
                }
            }

            // Perform slashing
            if (incorrectCount > 0) {
                address[] memory finalIncorrectVoters = new address[](incorrectCount);
                for (uint256 i = 0; i < incorrectCount; i++) {
                    finalIncorrectVoters[i] = incorrectOriginalVoters[i];
                }
                _slashVerifiers(finalIncorrectVoters, incorrectVoteStakePenalty, incorrectVoteReputationPenalty);
            }
        }

        // --- Distribute Challenger Stake ---
        if (challengeUpheld) {
            // Challenger was wrong. Transfer their stake to the treasury.
            challengeToken.transfer(treasury, challenge.stake);
        } else {
            // Challenger was right. Refund their stake.
            challengeToken.transfer(challenge.challenger, challenge.stake);
        }

        task.status = TaskStatus.Resolved;
        challenge.active = false;

        // Now, determine final outcome and interact with dMRVManager
        bool finalOutcomeIsApprove =
            (task.provisionalOutcome && challengeUpheld) || (!task.provisionalOutcome && !challengeUpheld);

        if (finalOutcomeIsApprove) {
            bytes memory data = abi.encode(1, false, bytes32(0), credentialCID);
            DMRVManager(dMRVManager).fulfillVerification(task.projectId, task.claimId, data);
        }

        emit ChallengeResolved(taskId, challengeUpheld);
    }

    /**
     * @notice Finalizes a task's resolution after the challenge period has passed without a challenge.
     * @dev If the provisional outcome was 'Approve', this function calls the dMRVManager to
     * fulfill the verification and mint credits.
     * @param taskId The ID of the task to finalize.
     * @param credentialCID The IPFS CID of the Verifiable Credential for this verification.
     */
    function finalizeResolution(bytes32 taskId, string calldata credentialCID) external nonReentrant {
        VerificationTask storage task = tasks[taskId];
        if (task.status != TaskStatus.Provisional) {
            revert ReputationweightedVerifier__InvalidTaskStatus(taskId, task.status);
        }
        if (block.timestamp < task.challengeDeadline) revert ReputationWeightedVerifier__ChallengePeriodNotOver();

        task.status = TaskStatus.Resolved;

        if (task.provisionalOutcome) {
            // Encode the data for the dMRVManager.
            // (creditAmount, updateMetadataOnly, signature, credentialCID)
            // For now, creditAmount is hardcoded to 1.
            bytes memory data = abi.encode(1, false, bytes32(0), credentialCID);
            DMRVManager(dMRVManager).fulfillVerification(task.projectId, task.claimId, data);
        }

        emit TaskResolved(taskId, task.provisionalOutcome, task.weightedApproveVotes, task.weightedRejectVotes);
    }

    /**
     * @notice The callback function called by the VRF Coordinator with the random words.
     * @dev This function is the designated receiver of the random values.
     *      It is protected by the onlyVRFCoordinator modifier.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external onlyVRFCoordinator {
        bytes32 taskId = vrfRequestToTaskId[requestId];
        if (taskId == bytes32(0)) revert ReputationWeightedVerifier__RequestIdNotFound();

        delete vrfRequestToTaskId[requestId]; // Prevent re-use of request ID

        _selectArbitrationCouncil(taskId, randomWords);
    }

    // --- Internal Logic ---

    /**
     * @notice Selects a random council of verifiers to arbitrate a challenge.
     * @dev Uses cryptographically secure randomness from Chainlink VRF.
     * @param taskId The ID of the task to select a council for.
     * @param randomWords The array of random numbers provided by the VRF.
     */
    function _selectArbitrationCouncil(bytes32 taskId, uint256[] memory randomWords) internal {
        Challenge storage challenge = challenges[taskId];
        VerificationTask storage task = tasks[taskId];

        address[] memory allVerifiers = verifierManager.getAllVerifiers();
        address[] memory eligibleCouncilMembers = new address[](allVerifiers.length);
        uint256 eligibleCount = 0;

        // Filter out verifiers who participated in the original vote
        for (uint256 i = 0; i < allVerifiers.length; i++) {
            if (task.votes[allVerifiers[i]] == Vote.None) {
                eligibleCouncilMembers[eligibleCount] = allVerifiers[i];
                eligibleCount++;
            }
        }

        // Ensure we have enough eligible members for the council
        if (eligibleCount < councilSize) {
            revert ReputationWeightedVerifier__NotEnoughVerifiers();
        }

        // Pseudo-randomly select the council members from the eligible list
        for (uint256 i = 0; i < councilSize; i++) {
            // Use the verified random word for this selection
            uint256 randomIndex = randomWords[i] % eligibleCount;

            address selected = eligibleCouncilMembers[randomIndex];
            challenge.councilMembers.push(selected);

            // Prevent re-selection by swapping the selected member with the last one
            eligibleCouncilMembers[randomIndex] = eligibleCouncilMembers[eligibleCount - 1];
            eligibleCount--;
        }

        // --- SET THE COUNCIL VOTING DEADLINE ---
        challenge.challengeVoteDeadline = uint64(block.timestamp + votingPeriod);
    }

    function _slashVerifiers(address[] memory incorrectVoters, uint256 stakePenalty, uint256 reputationPenalty)
        internal
    {
        for (uint256 i = 0; i < incorrectVoters.length; i++) {
            address verifier = incorrectVoters[i];
            // The verifierManager contract is responsible for slashing both stake and reputation.
            // This contract (ReputationWeightedVerifier) has been granted the SLASHER_ROLE on verifierManager.
            if (verifier != address(0)) {
                verifierManager.slash(verifier, stakePenalty, reputationPenalty);
            }
        }
    }

    function _getCouncilVotersByVote(Challenge storage challenge, bool voteToFind)
        internal
        view
        returns (address[] memory)
    {
        address[] memory voters = new address[](challenge.councilMembers.length);
        uint256 count = 0;

        for (uint256 i = 0; i < challenge.councilMembers.length; i++) {
            address member = challenge.councilMembers[i];
            // Check if the member has voted and if their vote matches the one we're looking for
            if (challenge.hasVotedOnChallenge[member] && challenge.councilVotes[member] == voteToFind) {
                voters[count] = member;
                count++;
            }
        }

        // Resize the array to the actual number of voters found
        assembly {
            mstore(voters, count)
        }

        return voters;
    }

    // --- View Functions & Admin ---

    function getTaskVotes(bytes32 taskId) external view returns (uint256, uint256) {
        return (tasks[taskId].weightedApproveVotes, tasks[taskId].weightedRejectVotes);
    }

    function getChallengeCouncil(bytes32 taskId) external view returns (address[] memory) {
        return challenges[taskId].councilMembers;
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
