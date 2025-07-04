// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../reputation-weighted/interfaces/IReputationWeightedVerifier.sol";
import "../reputation-weighted/interfaces/IVerifierManager.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";

// --- Custom Errors ---
error ArbitrationCouncil__InvalidDisputeStatus(bytes32 claimId, ArbitrationCouncil.DisputeStatus requiredStatus);
error ArbitrationCouncil__DisputeNotFound(bytes32 claimId);
error ArbitrationCouncil__NotCouncilMember(address caller);
error ArbitrationCouncil__VotingPeriodNotOver();
error ArbitrationCouncil__VotingPeriodOver();
error ArbitrationCouncil__AlreadyVoted();
error ArbitrationCouncil__ZeroAddress();
error ArbitrationCouncil__InsufficientStake();
error ArbitrationCouncil__TransferFailed();
error ArbitrationCouncil__DisputeAlreadyExists(bytes32 claimId);
error ArbitrationCouncil__RequestIdNotFound();
error ArbitrationCouncil__NotEnoughVerifiers();

// --- Upgradeable VRF Consumer ---

/**
 * @dev An upgradeable version of Chainlink's VRFConsumerBaseV2.
 * It replaces the constructor with an internal initializer function.
 */
abstract contract VRFConsumerBaseV2Upgradeable {
    error OnlyCoordinatorCanFulfill(address have, address want);

    address internal s_vrfCoordinator;

    function _initializeVRF(address vrfCoordinator) internal {
        if (vrfCoordinator == address(0)) revert ArbitrationCouncil__ZeroAddress();
        s_vrfCoordinator = vrfCoordinator;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal virtual;

    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != s_vrfCoordinator) {
            revert OnlyCoordinatorCanFulfill(msg.sender, s_vrfCoordinator);
        }
        fulfillRandomWords(requestId, randomWords);
    }
}

/**
 * @title ArbitrationCouncil
 * @author Genci Mehmeti
 * @dev Manages the decentralized dispute resolution process for verification outcomes.
 * It uses Chainlink VRF to securely select a peer council of verifiers to judge challenged decisions.
 */
contract ArbitrationCouncil is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    VRFConsumerBaseV2Upgradeable
{
    // --- Roles ---
    bytes32 public constant COUNCIL_ADMIN_ROLE = keccak256("COUNCIL_ADMIN_ROLE");
    bytes32 public constant VERIFIER_CONTRACT_ROLE = keccak256("VERIFIER_CONTRACT_ROLE");

    // --- Enums ---
    enum DisputeStatus {
        None,
        AwaitingRandomness,
        Voting,
        Resolved,
        Expired
    }

    // --- Data Structures ---
    struct Dispute {
        bytes32 claimId;
        address challenger;
        address defendant; // The address of the verifier module contract
        DisputeStatus status;
        uint256 totalWeightedVotes; // Stores the sum of (vote * reputation)
        uint256 totalReputationWeight; // Stores the sum of reputation of all who voted
        uint256 votingDeadline;
        mapping(address => uint256) votes; // Stores the quantitative vote of each council member
        mapping(address => bool) hasVoted;
        address[] councilMembers;
    }

    struct VrfRequest {
        bytes32 claimId;
        address challenger;
        address defendant;
    }

    // --- State Variables ---
    IERC20 public azeToken;
    IVerifierManager public verifierManager;
    address public treasury;

    uint256 public challengeStakeAmount;
    uint256 public votingPeriod;
    uint256 public councilSize;

    // Chainlink VRF variables
    VRFCoordinatorV2Interface public COORDINATOR;
    uint64 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public s_callbackGasLimit;
    uint16 public s_requestConfirmations;

    mapping(bytes32 => Dispute) public disputes;
    mapping(uint256 => VrfRequest) public vrfRequests;

    uint256[38] private __gap;

    // --- Events ---
    event DisputeCreated(
        bytes32 indexed claimId, address indexed challenger, address indexed defendant, uint256 vrfRequestId
    );
    event Voted(bytes32 indexed claimId, address indexed voter, uint256 votedAmount, uint256 weight);
    event DisputeResolved(bytes32 indexed claimId, uint256 finalAmount);
    event CouncilSelected(bytes32 indexed claimId, address[] councilMembers);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialAdmin,
        address _azeToken,
        address _verifierManager,
        address _treasury,
        address _vrfCoordinator,
        uint64 _vrfSubscriptionId
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _initializeVRF(_vrfCoordinator);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(COUNCIL_ADMIN_ROLE, initialAdmin);
        _grantRole(VERIFIER_CONTRACT_ROLE, initialAdmin);

        azeToken = IERC20(_azeToken);
        verifierManager = IVerifierManager(_verifierManager);
        treasury = _treasury;

        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        s_subscriptionId = _vrfSubscriptionId;
        // Constants like callbackGasLimit, requestConfirmations, and keyHash are set by admin
    }

    // --- Admin Functions ---

    function setVrfParams(bytes32 _keyHash, uint16 _requestConfirmations, uint32 _callbackGasLimit)
        external
        onlyRole(COUNCIL_ADMIN_ROLE)
    {
        s_keyHash = _keyHash;
        s_requestConfirmations = _requestConfirmations;
        s_callbackGasLimit = _callbackGasLimit;
    }

    function createDispute(bytes32 claimId, address challenger, address defendant)
        external
        onlyRole(VERIFIER_CONTRACT_ROLE)
        nonReentrant
        returns (bool)
    {
        if (challenger == address(0) || defendant == address(0)) revert ArbitrationCouncil__ZeroAddress();
        if (disputes[claimId].status != DisputeStatus.None) revert ArbitrationCouncil__DisputeAlreadyExists(claimId);

        if (azeToken.balanceOf(challenger) < challengeStakeAmount) revert ArbitrationCouncil__InsufficientStake();
        if (azeToken.allowance(challenger, address(this)) < challengeStakeAmount) {
            revert ArbitrationCouncil__InsufficientStake();
        }
        if (!azeToken.transferFrom(challenger, address(this), challengeStakeAmount)) {
            revert ArbitrationCouncil__TransferFailed();
        }

        uint256 requestId = COORDINATOR.requestRandomWords(
            s_keyHash, s_subscriptionId, s_requestConfirmations, s_callbackGasLimit, uint32(councilSize)
        );

        vrfRequests[requestId] = VrfRequest({claimId: claimId, challenger: challenger, defendant: defendant});

        Dispute storage dispute = disputes[claimId];
        dispute.status = DisputeStatus.AwaitingRandomness;

        emit DisputeCreated(claimId, challenger, defendant, requestId);
        return true;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        VrfRequest memory request = vrfRequests[requestId];
        if (request.claimId == bytes32(0)) revert ArbitrationCouncil__RequestIdNotFound();

        delete vrfRequests[requestId];

        address[] memory potentialJurors = verifierManager.getAllVerifiers();
        if (potentialJurors.length < councilSize) revert ArbitrationCouncil__NotEnoughVerifiers();

        address[] memory selectedCouncil = new address[](councilSize);
        uint256 jurorCount = 0;

        for (uint256 i = 0; i < randomWords.length && jurorCount < councilSize; i++) {
            uint256 randomIndex = randomWords[i] % potentialJurors.length;
            address candidate = potentialJurors[randomIndex];

            bool alreadySelected = false;
            for (uint256 j = 0; j < jurorCount; j++) {
                if (selectedCouncil[j] == candidate) {
                    alreadySelected = true;
                    break;
                }
            }

            if (candidate != request.defendant && candidate != request.challenger && !alreadySelected) {
                selectedCouncil[jurorCount] = candidate;
                jurorCount++;
            }
        }

        if (jurorCount < councilSize) {
            revert ArbitrationCouncil__NotEnoughVerifiers();
        }

        Dispute storage dispute = disputes[request.claimId];
        dispute.claimId = request.claimId;
        dispute.challenger = request.challenger;
        dispute.defendant = request.defendant;
        dispute.status = DisputeStatus.Voting;
        dispute.votingDeadline = block.timestamp + votingPeriod;
        dispute.councilMembers = selectedCouncil;

        emit CouncilSelected(request.claimId, selectedCouncil);
    }

    function setChallengeStakeAmount(uint256 _amount) external onlyRole(COUNCIL_ADMIN_ROLE) {
        challengeStakeAmount = _amount;
    }

    function setVotingPeriod(uint256 _period) external onlyRole(COUNCIL_ADMIN_ROLE) {
        votingPeriod = _period;
    }

    function setCouncilSize(uint256 _size) external onlyRole(COUNCIL_ADMIN_ROLE) {
        councilSize = _size;
    }

    // --- Core Functions ---

    /**
     * @notice Allows a selected council member to cast a quantitative vote on a dispute.
     * @param claimId The ID of the dispute.
     * @param votedAmount The amount the juror believes is the correct outcome for the claim.
     */
    function vote(bytes32 claimId, uint256 votedAmount) external nonReentrant {
        Dispute storage dispute = disputes[claimId];
        if (dispute.status != DisputeStatus.Voting) {
            revert ArbitrationCouncil__InvalidDisputeStatus(claimId, DisputeStatus.Voting);
        }
        if (block.timestamp > dispute.votingDeadline) revert ArbitrationCouncil__VotingPeriodOver();
        if (dispute.hasVoted[msg.sender]) revert ArbitrationCouncil__AlreadyVoted();

        bool isMember = false;
        for (uint256 i = 0; i < dispute.councilMembers.length; i++) {
            if (dispute.councilMembers[i] == msg.sender) {
                isMember = true;
                break;
            }
        }
        if (!isMember) revert ArbitrationCouncil__NotCouncilMember(msg.sender);

        dispute.hasVoted[msg.sender] = true;
        dispute.votes[msg.sender] = votedAmount;

        uint256 reputation = verifierManager.getVerifierReputation(msg.sender);

        dispute.totalWeightedVotes += votedAmount * reputation;
        dispute.totalReputationWeight += reputation;

        emit Voted(claimId, msg.sender, votedAmount, reputation);
    }

    function resolveDispute(bytes32 claimId) public nonReentrant {
        Dispute storage dispute = disputes[claimId];
        if (dispute.status != DisputeStatus.Voting) {
            revert ArbitrationCouncil__InvalidDisputeStatus(claimId, DisputeStatus.Voting);
        }
        if (block.timestamp <= dispute.votingDeadline) revert ArbitrationCouncil__VotingPeriodNotOver();

        dispute.status = DisputeStatus.Resolved;

        uint256 finalAmount = 0;
        if (dispute.totalReputationWeight > 0) {
            finalAmount = dispute.totalWeightedVotes / dispute.totalReputationWeight;
        }

        // For now, we assume the challenger always wins if a challenge occurs and is resolved.
        // The stake is returned to the challenger. A future iteration could make this logic
        // more nuanced based on how much `finalAmount` deviates from an original claim.
        if (!azeToken.transfer(dispute.challenger, challengeStakeAmount)) {
            revert ArbitrationCouncil__TransferFailed();
        }

        IReputationWeightedVerifier(dispute.defendant).processArbitrationResult(claimId, finalAmount);

        emit DisputeResolved(claimId, finalAmount);
    }

    // --- Private Helper Functions ---

    function _isCouncilMember(bytes32 claimId, address account) private view returns (bool) {
        address[] storage members = disputes[claimId].councilMembers;
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == account) {
                return true;
            }
        }
        return false;
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
