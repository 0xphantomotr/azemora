// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Contract Under Test
import {ArbitrationCouncil, ArbitrationCouncil__NotCouncilMember} from "../../src/governance/ArbitrationCouncil.sol";

// Mocks & Interfaces
import {MockERC20} from "../mocks/MockERC20.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";
import {IVerifierManager} from "../../src/reputation-weighted/interfaces/IVerifierManager.sol";
import {IReputationWeightedVerifier} from "../../src/reputation-weighted/interfaces/IReputationWeightedVerifier.sol";

// Mock for VerifierManager to control reputation scores
contract MockVerifierManager is IVerifierManager {
    mapping(address => uint256) public reputations;
    mapping(address => uint256) public stakes;
    address[] public verifiers;

    function setReputation(address verifier, uint256 reputation) external {
        reputations[verifier] = reputation;
    }

    function addVerifier(address verifier) external {
        verifiers.push(verifier);
    }

    function getVerifierReputation(address account) external view returns (uint256) {
        return reputations[account];
    }

    function getAllVerifiers() external view returns (address[] memory) {
        return verifiers;
    }

    // Unused functions required by the interface
    function isVerifier(address) external view returns (bool) {
        return true;
    }

    function slash(address) external {}

    function getVerifierStake(address account) external view returns (uint256) {
        return stakes[account];
    }
}

// Mock for the verifier contract that initiates the dispute
contract MockReputationWeightedVerifier is IReputationWeightedVerifier {
    uint256 public lastFinalAmount;

    function processArbitrationResult(bytes32, uint256 finalAmount) external {
        lastFinalAmount = finalAmount;
    }

    function reverseVerification(bytes32) external {}
}

contract ArbitrationCouncilTest is Test {
    // --- Contracts ---
    ArbitrationCouncil internal council;
    MockERC20 internal aztToken;
    MockVerifierManager internal verifierManager;
    MockReputationWeightedVerifier internal repWeightedVerifier;
    VRFCoordinatorV2Mock internal vrfCoordinator;

    // --- Users ---
    address internal admin;
    address internal challenger;
    address internal member1;
    address internal member2;
    address internal member3;

    // --- Constants ---
    uint256 internal constant CHALLENGE_STAKE_AMOUNT = 50e18;
    bytes32 internal constant CLAIM_ID = keccak256("test-claim");

    function setUp() public {
        admin = makeAddr("admin");
        challenger = makeAddr("challenger");
        member1 = makeAddr("member1");
        member2 = makeAddr("member2");
        member3 = makeAddr("member3");

        vm.startPrank(admin);

        // --- Deploy Mocks ---
        aztToken = new MockERC20("AZT", "AZT", 18);
        vrfCoordinator = new VRFCoordinatorV2Mock(0, 0);
        verifierManager = new MockVerifierManager();
        repWeightedVerifier = new MockReputationWeightedVerifier();

        // --- Deploy and Initialize ArbitrationCouncil ---
        council = ArbitrationCouncil(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new ArbitrationCouncil()),
                        abi.encodeCall(
                            ArbitrationCouncil.initialize,
                            (
                                admin,
                                address(aztToken),
                                address(verifierManager),
                                address(0), // treasury
                                address(vrfCoordinator),
                                1 // subscriptionId
                            )
                        )
                    )
                )
            )
        );

        // --- Configure System ---
        council.setVrfParams(keccak256("keyhash"), 3, 500000);
        council.setCouncilSize(3);
        council.setVotingPeriod(1 days);
        council.setChallengeStakeAmount(CHALLENGE_STAKE_AMOUNT);
        council.grantRole(council.VERIFIER_CONTRACT_ROLE(), address(this));

        vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(1, 100 ether);
        vrfCoordinator.addConsumer(1, address(council));

        // --- Setup User State ---
        aztToken.mint(challenger, CHALLENGE_STAKE_AMOUNT);

        // --- Populate Verifier Manager Mock ---
        verifierManager.addVerifier(member1);
        verifierManager.addVerifier(member2);
        verifierManager.addVerifier(member3);
        // Set up reputations: member1=100, member2=200, member3=300
        verifierManager.setReputation(member1, 100);
        verifierManager.setReputation(member2, 200);
        verifierManager.setReputation(member3, 300);

        vm.stopPrank();
    }

    /// @notice Tests the full dispute lifecycle, including creation, VRF-based council selection,
    ///         quantitative voting, and the final weighted-average calculation.
    function test_fullFlow_calculatesCorrectWeightedAverage() public {
        // --- Pre-validation ---
        assertEq(council.councilSize(), 3, "Initial council size should be 3");

        // 1. Create the dispute
        vm.prank(challenger);
        aztToken.approve(address(council), CHALLENGE_STAKE_AMOUNT);
        vm.prank(address(this)); // The test contract has the role to create disputes
        council.createDispute(CLAIM_ID, challenger, address(repWeightedVerifier));

        // --- Validate initial state of the new dispute ---
        (,,, ArbitrationCouncil.DisputeStatus statusBefore,,,,) = council.disputes(CLAIM_ID);
        assertEq(
            uint8(statusBefore),
            uint8(ArbitrationCouncil.DisputeStatus.AwaitingRandomness),
            "Dispute should be awaiting randomness"
        );

        // 2. Fulfill VRF request to select the council members
        // The random words are crafted to select member1, member2, and member3 (indices 0, 1, 2)
        uint256 vrfRequestId = 1;
        uint256[] memory randomWords = new uint256[](3);
        randomWords[0] = 0;
        randomWords[1] = 1;
        randomWords[2] = 2;
        vrfCoordinator.fulfillRandomWordsWithOverride(vrfRequestId, address(council), randomWords);

        // 3. Council members cast their quantitative votes
        uint256 vote1 = 70; // score of 70%
        uint256 vote2 = 85; // score of 85%
        uint256 vote3 = 95; // score of 95%
        vm.prank(member1);
        council.vote(CLAIM_ID, vote1);
        vm.prank(member2);
        council.vote(CLAIM_ID, vote2);
        vm.prank(member3);
        council.vote(CLAIM_ID, vote3);

        // 4. Resolve the dispute after the voting period
        vm.warp(block.timestamp + 2 days);
        council.resolveDispute(CLAIM_ID);

        // 5. Verify the final outcome
        // Expected = ((70 * 100) + (85 * 200) + (95 * 300)) / (100 + 200 + 300)
        // Expected = (7000 + 17000 + 28500) / 600
        // Expected = 52500 / 600 = 87.5
        // Solidity integer division result: 87
        uint256 expectedOutcome = 87;

        (
            , // claimId
            , // challenger
            , // defendant
            ArbitrationCouncil.DisputeStatus statusAfter, // 4th field
            , // totalWeightedVotes
            , // totalReputationWeight
            uint256 quantitativeOutcome, // 7th field
                // votingDeadline
        ) = council.disputes(CLAIM_ID);

        assertEq(uint8(statusAfter), uint8(ArbitrationCouncil.DisputeStatus.Resolved), "Dispute should be Resolved");
        assertEq(quantitativeOutcome, expectedOutcome, "Calculated weighted average is incorrect");
        assertEq(
            repWeightedVerifier.lastFinalAmount(), expectedOutcome, "Verifier was not notified with correct amount"
        );
    }

    /// @notice Tests that the vote function reverts if called by an address that is not part of the selected council.
    function test_revert_vote_if_not_council_member() public {
        // 1. Create the dispute and select the council (same setup as the full flow)
        vm.prank(challenger);
        aztToken.approve(address(council), CHALLENGE_STAKE_AMOUNT);
        vm.prank(address(this));
        // The createDispute function doesn't return the ID, but it is deterministic.
        // We use the same CLAIM_ID constant as the other test.
        council.createDispute(CLAIM_ID, challenger, address(repWeightedVerifier));

        uint256 vrfRequestId = 1;
        uint256[] memory randomWords = new uint256[](3);
        randomWords[0] = 0; // Selects member1
        randomWords[1] = 1; // Selects member2
        randomWords[2] = 2; // Selects member3
        vrfCoordinator.fulfillRandomWordsWithOverride(vrfRequestId, address(council), randomWords);

        // 2. Attempt to vote from an unauthorized address
        address unauthorizedVoter = makeAddr("unauthorized");
        vm.prank(unauthorizedVoter);

        // 3. Assert that the call reverts with the correct error
        vm.expectRevert(abi.encodeWithSelector(ArbitrationCouncil__NotCouncilMember.selector, unauthorizedVoter));
        council.vote(CLAIM_ID, 50); // The vote amount doesn't matter here
    }
}
