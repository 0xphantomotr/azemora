// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Contract Under Test
import {
    ArbitrationCouncil,
    ArbitrationCouncil__NotCouncilMember,
    ArbitrationCouncil__InvalidDisputeStatus,
    ArbitrationCouncil__FraudNotConfirmed,
    ArbitrationCouncil__MerkleRootAlreadySet,
    ArbitrationCouncil__InsufficientFundsForBounties
} from "../../src/governance/ArbitrationCouncil.sol";

// Mocks & Interfaces
import {MockERC20} from "../mocks/MockERC20.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {IVerifierManager} from "../../src/reputation-weighted/interfaces/IVerifierManager.sol";
import {IReputationWeightedVerifier} from "../../src/reputation-weighted/interfaces/IReputationWeightedVerifier.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// --- Embedded Test Library for Merkle Proofs ---
library MerkleTest {
    function getRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 0) {
            return bytes32(0);
        }
        bytes32[] memory nodes = leaves;
        while (nodes.length > 1) {
            bytes32[] memory newNodes = new bytes32[]((nodes.length + 1) / 2);
            for (uint256 i = 0; i < newNodes.length; i++) {
                uint256 j = i * 2;
                bytes32 left = nodes[j];
                bytes32 right = (j + 1 < nodes.length) ? nodes[j + 1] : left;
                if (left < right) {
                    newNodes[i] = keccak256(abi.encodePacked(left, right));
                } else {
                    newNodes[i] = keccak256(abi.encodePacked(right, left));
                }
            }
            nodes = newNodes;
        }
        return nodes[0];
    }

    function getProof(bytes32[] memory leaves, uint256 leafIndex) internal pure returns (bytes32[] memory) {
        uint256 numLayers = 0;
        uint256 n = leaves.length;
        if (n == 0) return new bytes32[](0);
        while (n > 1) {
            numLayers++;
            n = (n + 1) / 2;
        }

        bytes32[] memory proof = new bytes32[](numLayers);
        bytes32[] memory currentLayer = leaves;

        for (uint256 i = 0; i < numLayers; i++) {
            uint256 siblingIndex;
            if (leafIndex % 2 == 0) {
                siblingIndex = leafIndex + 1;
            } else {
                siblingIndex = leafIndex - 1;
            }

            if (siblingIndex < currentLayer.length) {
                proof[i] = currentLayer[siblingIndex];
            } else {
                proof[i] = currentLayer[leafIndex];
            }

            bytes32[] memory nextLayer = new bytes32[]((currentLayer.length + 1) / 2);
            for (uint256 j = 0; j < nextLayer.length; j++) {
                uint256 leftIndex = j * 2;
                uint256 rightIndex = leftIndex + 1;

                bytes32 left = currentLayer[leftIndex];
                bytes32 right = (rightIndex < currentLayer.length) ? currentLayer[rightIndex] : left;

                if (left < right) {
                    nextLayer[j] = keccak256(abi.encodePacked(left, right));
                } else {
                    nextLayer[j] = keccak256(abi.encodePacked(right, left));
                }
            }
            currentLayer = nextLayer;
            leafIndex /= 2;
        }

        return proof;
    }
}

// Mock for VerifierManager to control reputation scores
contract MockVerifierManager is IVerifierManager {
    mapping(address => uint256) public reputations;
    mapping(address => uint256) public stakes;
    address[] public verifiers;
    MockERC20 public aztToken;

    constructor(address _token) {
        aztToken = MockERC20(_token);
    }

    function setReputation(address verifier, uint256 reputation) external {
        reputations[verifier] = reputation;
    }

    function setStake(address verifier, uint256 amount) external {
        stakes[verifier] = amount;
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

    function isVerifier(address) external pure returns (bool) {
        return true;
    }

    function slash(address verifier, address compensationTarget) external {
        uint256 stakeToSlash = stakes[verifier];
        stakes[verifier] = 0;
        aztToken.transfer(compensationTarget, stakeToSlash);
    }

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
    VRFCoordinatorV2_5Mock internal vrfCoordinator;

    // --- Users ---
    address internal admin;
    address internal challenger;
    address internal member1;
    address internal member2;
    address internal member3;
    address internal victim1;
    address internal victim2;
    address internal treasury;
    address internal keeper;

    // Keys for signing
    uint256 internal challengerPrivateKey = 0x123;

    // --- Constants ---
    uint256 internal constant CHALLENGE_STAKE_AMOUNT = 50e18;
    uint256 internal constant KEEPER_BOUNTY = 2e18;
    bytes32 internal constant CLAIM_ID = keccak256("test_claim_1");

    function setUp() public {
        admin = makeAddr("admin");
        challenger = vm.addr(challengerPrivateKey);
        member1 = makeAddr("member1");
        member2 = makeAddr("member2");
        member3 = makeAddr("member3");
        victim1 = makeAddr("victim1");
        victim2 = makeAddr("victim2");
        treasury = makeAddr("treasury");
        keeper = makeAddr("keeper");

        vm.startPrank(admin);

        // --- Deploy Mocks ---
        aztToken = new MockERC20("AZT", "AZT", 18);
        vrfCoordinator = new VRFCoordinatorV2_5Mock(0, 0, 1);
        verifierManager = new MockVerifierManager(address(aztToken));
        repWeightedVerifier = new MockReputationWeightedVerifier();

        uint256 subId = vrfCoordinator.createSubscription();

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
                                treasury,
                                address(vrfCoordinator),
                                subId
                            )
                        )
                    )
                )
            )
        );

        // --- Configure System as Admin ---
        council.setVrfParams(keccak256("keyhash"), 3, 500000);
        council.setCouncilSize(3);
        council.setVotingPeriod(1 days);
        council.setChallengeStakeAmount(CHALLENGE_STAKE_AMOUNT);
        council.grantRole(council.VERIFIER_CONTRACT_ROLE(), address(this));
        council.setFraudThreshold(50);
        council.setKeeperBounty(KEEPER_BOUNTY);

        vrfCoordinator.fundSubscription(subId, 100 ether);
        vrfCoordinator.addConsumer(subId, address(council));

        // --- Setup User State as Admin ---
        aztToken.mint(challenger, CHALLENGE_STAKE_AMOUNT);
        aztToken.mint(address(verifierManager), 1_000_000e18);

        // --- Populate Verifier Manager Mock as Admin ---
        verifierManager.addVerifier(member1);
        verifierManager.addVerifier(member2);
        verifierManager.addVerifier(member3);
        verifierManager.setReputation(member1, 100);
        verifierManager.setReputation(member2, 200);
        verifierManager.setReputation(member3, 300);
        verifierManager.setStake(address(repWeightedVerifier), 100e18);

        vm.stopPrank();

        // --- Pre-approve spending for the challenger as Challenger ---
        vm.startPrank(challenger);
        aztToken.approve(address(council), CHALLENGE_STAKE_AMOUNT);
        vm.stopPrank();
    }

    function _getDisputeSignature(bytes32 claimId, address defendantAddress, uint256 privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = council.domainSeparator();
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, keccak256(abi.encode(claimId, defendantAddress))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Tests the full dispute lifecycle, including creation, VRF-based council selection,
    ///         quantitative voting, and the final weighted-average calculation.
    function test_fullFlow_calculatesCorrectWeightedAverage() public {
        assertEq(council.councilSize(), 3, "Initial council size should be 3");

        vm.prank(address(this));
        bytes memory signature = _getDisputeSignature(CLAIM_ID, address(repWeightedVerifier), challengerPrivateKey);
        council.createDispute(CLAIM_ID, address(repWeightedVerifier), signature);

        (,,, ArbitrationCouncil.DisputeStatus statusBefore,,,,) = council.disputes(CLAIM_ID);
        assertEq(
            uint8(statusBefore),
            uint8(ArbitrationCouncil.DisputeStatus.AwaitingRandomness),
            "Dispute should be awaiting randomness"
        );

        uint256 vrfRequestId = 1;
        uint256[] memory randomWords = new uint256[](3);
        randomWords[0] = 0;
        randomWords[1] = 1;
        randomWords[2] = 2;
        vrfCoordinator.fulfillRandomWordsWithOverride(vrfRequestId, address(council), randomWords);

        uint256 vote1 = 70;
        uint256 vote2 = 85;
        uint256 vote3 = 95;
        vm.prank(member1);
        council.vote(CLAIM_ID, vote1);
        vm.prank(member2);
        council.vote(CLAIM_ID, vote2);
        vm.prank(member3);
        council.vote(CLAIM_ID, vote3);

        vm.warp(block.timestamp + 2 days);
        council.resolveDispute(CLAIM_ID);

        (,,,,,, uint256 finalOutcome,) = council.disputes(CLAIM_ID);
        repWeightedVerifier.processArbitrationResult(CLAIM_ID, finalOutcome);

        uint256 expectedOutcome = 87;

        (,,, ArbitrationCouncil.DisputeStatus statusAfter,,, uint256 quantitativeOutcome,) = council.disputes(CLAIM_ID);

        assertEq(uint8(statusAfter), uint8(ArbitrationCouncil.DisputeStatus.Resolved), "Dispute should be Resolved");
        assertEq(quantitativeOutcome, expectedOutcome, "Calculated weighted average is incorrect");
        assertEq(
            repWeightedVerifier.lastFinalAmount(), expectedOutcome, "Verifier was not notified with correct amount"
        );
    }

    function _setupDisputeForResolution() internal {
        vm.prank(address(this));
        bytes memory signature = _getDisputeSignature(CLAIM_ID, address(repWeightedVerifier), challengerPrivateKey);
        council.createDispute(CLAIM_ID, address(repWeightedVerifier), signature);

        uint256 vrfRequestId = 1;
        uint256[] memory randomWords = new uint256[](3);
        randomWords[0] = 0;
        randomWords[1] = 1;
        randomWords[2] = 2;
        vrfCoordinator.fulfillRandomWordsWithOverride(vrfRequestId, address(council), randomWords);
    }

    function _setupAndVoteFraudulent() internal {
        _setupDisputeForResolution();
        vm.prank(member1);
        council.vote(CLAIM_ID, 10);
        vm.prank(member2);
        council.vote(CLAIM_ID, 20);
        vm.warp(block.timestamp + 2 days);
    }

    function _setupFraudulentDispute() internal returns (bytes32 merkleRoot, bytes32[] memory proof1) {
        vm.prank(address(this));
        bytes memory signature = _getDisputeSignature(CLAIM_ID, address(repWeightedVerifier), challengerPrivateKey);
        council.createDispute(CLAIM_ID, address(repWeightedVerifier), signature);

        uint256 vrfRequestId = 1;
        uint256[] memory randomWords = new uint256[](3);
        randomWords[0] = 0;
        randomWords[1] = 1;
        randomWords[2] = 2;
        vrfCoordinator.fulfillRandomWordsWithOverride(vrfRequestId, address(council), randomWords);

        vm.prank(member1);
        council.vote(CLAIM_ID, 10);
        vm.prank(member2);
        council.vote(CLAIM_ID, 20);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(victim1, uint256(10e18)));
        leaves[1] = keccak256(abi.encodePacked(victim2, uint256(20e18)));

        merkleRoot = MerkleTest.getRoot(leaves);
        proof1 = MerkleTest.getProof(leaves, 0);

        vm.warp(block.timestamp + 2 days);
        vm.prank(keeper);
        council.resolveDispute(CLAIM_ID);
        vm.prank(admin);
        council.setCompensationMerkleRoot(CLAIM_ID, merkleRoot);
        vm.stopPrank();
    }

    function test_claimCompensation_succeeds_with_valid_proof() public {
        (, bytes32[] memory proof) = _setupFraudulentDispute();
        uint256 claimAmount = 10e18;
        uint256 initialBalance = aztToken.balanceOf(victim1);

        vm.prank(victim1);
        council.claimCompensation(CLAIM_ID, victim1, claimAmount, proof);

        uint256 finalBalance = aztToken.balanceOf(victim1);
        assertEq(finalBalance - initialBalance, claimAmount, "Victim should receive correct compensation amount");
    }

    function test_revert_if_claim_twice() public {
        (, bytes32[] memory proof) = _setupFraudulentDispute();
        uint256 claimAmount = 10e18;

        vm.prank(victim1);
        council.claimCompensation(CLAIM_ID, victim1, claimAmount, proof);

        vm.prank(victim1);
        vm.expectRevert("Already claimed");
        council.claimCompensation(CLAIM_ID, victim1, claimAmount, proof);
    }

    function test_revert_if_invalid_proof() public {
        (, bytes32[] memory proof) = _setupFraudulentDispute();
        uint256 claimAmount = 20e18;

        vm.prank(victim1);
        vm.expectRevert("Invalid merkle proof");
        council.claimCompensation(CLAIM_ID, victim1, claimAmount, proof);
    }

    function test_revert_vote_if_not_council_member() public {
        vm.prank(address(this));
        bytes memory signature = _getDisputeSignature(CLAIM_ID, address(repWeightedVerifier), challengerPrivateKey);
        council.createDispute(CLAIM_ID, address(repWeightedVerifier), signature);

        uint256 vrfRequestId = 1;
        uint256[] memory randomWords = new uint256[](3);
        randomWords[0] = 0;
        randomWords[1] = 1;
        randomWords[2] = 2;
        vrfCoordinator.fulfillRandomWordsWithOverride(vrfRequestId, address(council), randomWords);

        address unauthorizedVoter = makeAddr("unauthorized");
        vm.prank(unauthorizedVoter);

        vm.expectRevert(abi.encodeWithSelector(ArbitrationCouncil__NotCouncilMember.selector, unauthorizedVoter));
        council.vote(CLAIM_ID, 50);
    }

    function test_resolveDispute_paysKeeperBounty_onFraud() public {
        _setupAndVoteFraudulent();

        uint256 keeperBalanceBefore = aztToken.balanceOf(keeper);
        uint256 challengerBalanceBefore = aztToken.balanceOf(challenger);
        uint256 defendantStake = verifierManager.getVerifierStake(address(repWeightedVerifier));

        vm.prank(keeper);
        council.resolveDispute(CLAIM_ID);

        uint256 keeperBalanceAfter = aztToken.balanceOf(keeper);
        uint256 challengerBalanceAfter = aztToken.balanceOf(challenger);

        assertEq(keeperBalanceAfter - keeperBalanceBefore, KEEPER_BOUNTY, "Keeper bounty not paid");

        uint256 expectedChallengerBounty = (defendantStake * 10) / 100;
        uint256 expectedChallengerReturn = CHALLENGE_STAKE_AMOUNT + expectedChallengerBounty;

        assertEq(
            challengerBalanceAfter - challengerBalanceBefore,
            expectedChallengerReturn,
            "Challenger did not receive stake back + bounty"
        );
    }

    function test_resolveDispute_paysKeeperBounty_onNoFraud() public {
        _setupDisputeForResolution();
        vm.prank(member1);
        council.vote(CLAIM_ID, 80);
        vm.warp(block.timestamp + 2 days);

        uint256 keeperBalanceBefore = aztToken.balanceOf(keeper);
        uint256 defendantBalanceBefore = aztToken.balanceOf(address(repWeightedVerifier));

        vm.prank(keeper);
        council.resolveDispute(CLAIM_ID);

        uint256 keeperBalanceAfter = aztToken.balanceOf(keeper);
        uint256 defendantBalanceAfter = aztToken.balanceOf(address(repWeightedVerifier));

        assertEq(keeperBalanceAfter - keeperBalanceBefore, KEEPER_BOUNTY, "Keeper bounty not paid on no-fraud");
        assertEq(
            defendantBalanceAfter - defendantBalanceBefore,
            CHALLENGE_STAKE_AMOUNT - KEEPER_BOUNTY,
            "Defendant did not receive the remainder of the challenger's stake"
        );
    }

    function test_revert_if_bounty_exceeds_funds() public {
        _setupAndVoteFraudulent();
        uint256 defendantStake = verifierManager.getVerifierStake(address(repWeightedVerifier));
        uint256 excessiveBounty = defendantStake + 1;

        vm.prank(admin);
        council.setKeeperBounty(excessiveBounty);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(ArbitrationCouncil__InsufficientFundsForBounties.selector);
        council.resolveDispute(CLAIM_ID);
    }

    function test_revert_setMerkleRoot_if_not_admin() public {
        (bytes32 merkleRoot,) = _setupFraudulentDispute();

        vm.startPrank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                challenger,
                council.COUNCIL_ADMIN_ROLE()
            )
        );
        council.setCompensationMerkleRoot(CLAIM_ID, merkleRoot);
        vm.stopPrank();
    }

    function test_revert_setMerkleRoot_if_dispute_not_resolved() public {
        vm.prank(address(this));
        bytes memory signature = _getDisputeSignature(CLAIM_ID, address(repWeightedVerifier), challengerPrivateKey);
        council.createDispute(CLAIM_ID, address(repWeightedVerifier), signature);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationCouncil__InvalidDisputeStatus.selector, CLAIM_ID, ArbitrationCouncil.DisputeStatus.Resolved
            )
        );
        council.setCompensationMerkleRoot(CLAIM_ID, bytes32(uint256(1)));
    }

    function test_revert_setMerkleRoot_if_not_fraud() public {
        this.test_fullFlow_calculatesCorrectWeightedAverage();

        vm.prank(admin);
        vm.expectRevert(ArbitrationCouncil__FraudNotConfirmed.selector);
        council.setCompensationMerkleRoot(CLAIM_ID, bytes32(uint256(1)));
    }

    function test_revert_setMerkleRoot_if_root_already_set() public {
        (bytes32 merkleRoot,) = _setupFraudulentDispute();

        vm.prank(admin);
        vm.expectRevert(ArbitrationCouncil__MerkleRootAlreadySet.selector);
        council.setCompensationMerkleRoot(CLAIM_ID, merkleRoot);
    }
}
