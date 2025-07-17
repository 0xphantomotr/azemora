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
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// --- Interfaces ---
// IStakingManager interface removed

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
error ArbitrationCouncil__FraudNotConfirmed();
error ArbitrationCouncil__MerkleRootAlreadySet();
error ArbitrationCouncil__MerkleRootCannotBeZero();
error ArbitrationCouncil__InsufficientFundsForBounties();

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
    // --- EIP-712 ---
    bytes32 private DOMAIN_SEPARATOR;
    uint256 private chainId;

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
        uint256 quantitativeOutcome; // Stores the final weighted-average outcome
        uint64 votingDeadline; // Changed from uint256 for gas packing
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
    // IStakingManager public stakingManager; <-- This line is removed
    address public treasury;

    uint256 public challengeStakeAmount;
    uint256 public votingPeriod;
    uint256 public councilSize;
    uint256 public fraudThreshold; // e.g., 50 for 50%. If outcome < threshold, it's fraud.
    uint256 public keeperBounty; // AZE tokens rewarded to the address that calls resolveDispute

    // Chainlink VRF variables
    VRFCoordinatorV2Interface public COORDINATOR;
    uint64 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public s_callbackGasLimit;
    uint16 public s_requestConfirmations;

    mapping(bytes32 => Dispute) public disputes;
    mapping(uint256 => VrfRequest) public vrfRequests;
    mapping(bytes32 => bytes32) public disputeMerkleRoots;
    mapping(bytes32 => mapping(address => bool)) public hasClaimed;

    uint256[38] private __gap;

    // --- Events ---
    event DisputeCreated(
        bytes32 indexed claimId, address indexed challenger, address indexed defendant, uint256 vrfRequestId
    );
    event Voted(bytes32 indexed claimId, address indexed voter, uint256 votedAmount, uint256 weight);
    event DisputeResolved(bytes32 indexed claimId, uint256 finalAmount, bytes32 merkleRoot);
    event CouncilSelected(bytes32 indexed claimId, address[] councilMembers);
    event CompensationClaimed(bytes32 indexed claimId, address indexed user, uint256 amount);
    event MerkleRootSet(bytes32 indexed claimId, bytes32 merkleRoot);
    event KeeperRewarded(address indexed keeper, uint256 amount);

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
        _setDomainSeparator();

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

    // setStakingManager function removed

    function setFraudThreshold(uint256 _threshold) external onlyRole(COUNCIL_ADMIN_ROLE) {
        fraudThreshold = _threshold;
    }

    function setKeeperBounty(uint256 _bountyAmount) external onlyRole(COUNCIL_ADMIN_ROLE) {
        keeperBounty = _bountyAmount;
    }

    function setCompensationMerkleRoot(bytes32 claimId, bytes32 merkleRoot) external onlyRole(COUNCIL_ADMIN_ROLE) {
        Dispute storage dispute = disputes[claimId];
        // Check 1: Dispute must be resolved
        if (dispute.status != DisputeStatus.Resolved) {
            revert ArbitrationCouncil__InvalidDisputeStatus(claimId, DisputeStatus.Resolved);
        }
        // Check 2: The outcome must have been fraudulent
        if (dispute.quantitativeOutcome >= fraudThreshold) {
            revert ArbitrationCouncil__FraudNotConfirmed();
        }
        // Check 3: Root cannot be set twice
        if (disputeMerkleRoots[claimId] != bytes32(0)) {
            revert ArbitrationCouncil__MerkleRootAlreadySet();
        }
        // Check 4: Root cannot be empty
        if (merkleRoot == bytes32(0)) {
            revert ArbitrationCouncil__MerkleRootCannotBeZero();
        }

        disputeMerkleRoots[claimId] = merkleRoot;
        emit MerkleRootSet(claimId, merkleRoot);
    }

    function createDispute(bytes32 claimId, address defendant, bytes calldata signature)
        external
        onlyRole(VERIFIER_CONTRACT_ROLE)
        nonReentrant
        returns (bool)
    {
        // --- Signature Verification ---
        // The challenger address is now securely recovered from the signature itself.
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", domainSeparator(), keccak256(abi.encode(claimId, defendant))));
        address challenger = ECDSA.recover(digest, signature);

        if (challenger == address(0) || defendant == address(0)) revert ArbitrationCouncil__ZeroAddress();
        if (disputes[claimId].status != DisputeStatus.None) revert ArbitrationCouncil__DisputeAlreadyExists(claimId);

        // --- Checks-Effects-Interactions Pattern ---
        // Effects:
        // Set status to AwaitingRandomness immediately to prevent reentrancy for this claimId.
        disputes[claimId].status = DisputeStatus.AwaitingRandomness;

        // Interactions:
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

        emit DisputeCreated(claimId, challenger, defendant, requestId);
        return true;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override nonReentrant {
        VrfRequest memory vrfRequest = vrfRequests[requestId];
        if (vrfRequest.claimId == bytes32(0)) revert ArbitrationCouncil__RequestIdNotFound();

        delete vrfRequests[requestId];

        address[] memory allVerifiers = verifierManager.getAllVerifiers();
        uint256 numVerifiers = allVerifiers.length;

        // Filter out the challenger and defendant from the list of potential jurors
        address[] memory potentialJurors = new address[](numVerifiers);
        uint256 jurorCount = 0;
        for (uint256 i = 0; i < numVerifiers; i++) {
            address verifier = allVerifiers[i];
            if (verifier != vrfRequest.challenger && verifier != vrfRequest.defendant) {
                potentialJurors[jurorCount] = verifier;
                jurorCount++;
            }
        }

        if (jurorCount < councilSize) {
            revert ArbitrationCouncil__NotEnoughVerifiers();
        }

        // --- Efficient Shuffle (Fisher-Yates style) ---
        // We use the provided random words to shuffle the first 'councilSize' positions
        // of our potentialJurors array.
        for (uint256 i = 0; i < councilSize; i++) {
            // Use a random number to pick an index from the rest of the array
            uint256 randomIndex = i + (randomWords[i] % (jurorCount - i));

            // Swap the element at the random index with the current element
            address temp = potentialJurors[i];
            potentialJurors[i] = potentialJurors[randomIndex];
            potentialJurors[randomIndex] = temp;
        }

        // --- Select the final council ---
        // The first 'councilSize' elements are now our randomly selected, unique jurors.
        address[] memory selectedCouncil = new address[](councilSize);
        for (uint256 i = 0; i < councilSize; i++) {
            selectedCouncil[i] = potentialJurors[i];
        }

        Dispute storage dispute = disputes[vrfRequest.claimId];
        dispute.claimId = vrfRequest.claimId;
        dispute.challenger = vrfRequest.challenger;
        dispute.defendant = vrfRequest.defendant;
        dispute.status = DisputeStatus.Voting;
        dispute.councilMembers = selectedCouncil;
        dispute.votingDeadline = uint64(block.timestamp + votingPeriod);

        emit CouncilSelected(vrfRequest.claimId, selectedCouncil);
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
        if (block.timestamp > uint256(dispute.votingDeadline)) revert ArbitrationCouncil__VotingPeriodOver();
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

    function resolveDispute(bytes32 claimId) external nonReentrant {
        Dispute storage dispute = disputes[claimId];
        if (dispute.status != DisputeStatus.Voting) {
            revert ArbitrationCouncil__InvalidDisputeStatus(claimId, DisputeStatus.Voting);
        }
        if (block.timestamp <= uint256(dispute.votingDeadline)) revert ArbitrationCouncil__VotingPeriodNotOver();

        uint256 finalOutcome = 0;
        if (dispute.totalReputationWeight > 0) {
            finalOutcome = dispute.totalWeightedVotes / dispute.totalReputationWeight;
        }

        dispute.quantitativeOutcome = finalOutcome;
        dispute.status = DisputeStatus.Resolved;

        // If the final outcome is below the fraud threshold, the challenge was successful.
        if (finalOutcome < fraudThreshold) {
            // The amount to slash is the defendant's stake from the verifier manager.
            // Note: The defendant in an arbitration case is the Verifier Module contract itself.
            // Slashing is intended for the verifiers *behind* that module. This logic
            // assumes the verifier module is the staker, which needs review.
            // For now, we proceed with the assumption that the defendant *is* the staker.
            uint256 slashAmount = verifierManager.getVerifierStake(dispute.defendant);
            if (slashAmount == 0) revert ArbitrationCouncil__FraudNotConfirmed();

            uint256 challengerBounty = (slashAmount * 10) / 100; // 10% bounty
            if (slashAmount < challengerBounty + keeperBounty) {
                revert ArbitrationCouncil__InsufficientFundsForBounties();
            }

            // 1. Return the challenger's original stake.
            if (!azeToken.transfer(dispute.challenger, challengeStakeAmount)) {
                revert ArbitrationCouncil__TransferFailed();
            }

            // 2. Slash the defendant's stake, transferring the funds to this contract to serve as
            //    the compensation pool and bounty source.
            verifierManager.slash(dispute.defendant, address(this));

            // 3. From the newly received slashed funds, pay the challenger's bounty.
            if (challengerBounty > 0 && !azeToken.transfer(dispute.challenger, challengerBounty)) {
                revert ArbitrationCouncil__TransferFailed();
            }

            // 4. Pay the keeper's bounty.
            if (keeperBounty > 0 && !azeToken.transfer(msg.sender, keeperBounty)) {
                revert ArbitrationCouncil__TransferFailed();
            }
            emit KeeperRewarded(msg.sender, keeperBounty);

            // The Merkle root is now set in a separate, admin-only function.
            // disputeMerkleRoots[claimId] = merkleRoot;
        } else {
            // If the challenge failed, the defendant was correct.
            // Pay the keeper from the challenger's stake before returning the rest to the defendant.
            if (challengeStakeAmount < keeperBounty) {
                revert ArbitrationCouncil__InsufficientFundsForBounties();
            }

            if (keeperBounty > 0) {
                if (!azeToken.transfer(msg.sender, keeperBounty)) {
                    revert ArbitrationCouncil__TransferFailed();
                }
                emit KeeperRewarded(msg.sender, keeperBounty);
            }

            uint256 remainingStake = challengeStakeAmount - keeperBounty;
            if (remainingStake > 0 && !azeToken.transfer(dispute.defendant, remainingStake)) {
                revert ArbitrationCouncil__TransferFailed();
            }
        }

        // Notify the originating verifier module of the final outcome.
        IReputationWeightedVerifier(dispute.defendant).processArbitrationResult(claimId, finalOutcome);

        emit DisputeResolved(claimId, finalOutcome, disputeMerkleRoots[claimId]);
    }

    function claimCompensation(bytes32 claimId, address recipient, uint256 amount, bytes32[] calldata merkleProof)
        external
        nonReentrant
    {
        if (disputes[claimId].status != DisputeStatus.Resolved) {
            revert ArbitrationCouncil__InvalidDisputeStatus(claimId, DisputeStatus.Resolved);
        }

        if (hasClaimed[claimId][recipient]) revert("Already claimed");

        bytes32 merkleRoot = disputeMerkleRoots[claimId];
        if (merkleRoot == bytes32(0)) revert("No merkle root for this dispute");

        bytes32 leaf = keccak256(abi.encodePacked(recipient, amount));

        if (!MerkleProof.verify(merkleProof, merkleRoot, leaf)) revert("Invalid merkle proof");

        hasClaimed[claimId][recipient] = true;
        if (!azeToken.transfer(recipient, amount)) {
            revert ArbitrationCouncil__TransferFailed();
        }

        emit CompensationClaimed(claimId, recipient, amount);
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

    function _setDomainSeparator() private {
        chainId = block.chainid;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ArbitrationCouncil")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function domainSeparator() public view returns (bytes32) {
        return block.chainid == chainId ? DOMAIN_SEPARATOR : _calculateDomainSeparator();
    }

    function _calculateDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ArbitrationCouncil")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
