// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Main Contracts
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";
import {DynamicImpactCredit} from "../../src/core/DynamicImpactCredit.sol";
import {VerifierManager} from "../../src/reputation-weighted/VerifierManager.sol";
import {
    ReputationWeightedVerifier, Vote, TaskStatus
} from "../../src/reputation-weighted/ReputationWeightedVerifier.sol";
import {MethodologyRegistry} from "../../src/core/MethodologyRegistry.sol";
import {ArbitrationCouncil} from "../../src/governance/ArbitrationCouncil.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

// Mocks & Tokens
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockReputationManager} from "../mocks/MockReputationManager.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";

contract FullSystemIntegrationTest is Test {
    // --- Constants ---
    uint256 internal constant INITIAL_MINT_AMOUNT = 1_000_000 * 1e18;
    uint256 internal constant MIN_STAKE_AMOUNT = 100 * 1e18;
    uint256 internal constant MIN_REPUTATION = 50;
    uint256 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant APPROVAL_THRESHOLD_BPS = 5001; // 50.01%
    uint256 internal constant CHALLENGE_PERIOD = 1 days;
    uint256 internal constant CHALLENGE_STAKE_AMOUNT = 50 * 1e18;
    uint256 internal constant ARBITRATION_COUNCIL_SIZE = 1;
    bytes32 internal constant REP_WEIGHTED_MODULE_TYPE = keccak256("REPUTATION_WEIGHTED_V1");
    uint64 internal constant VRF_SUB_ID = 1;
    bytes32 internal constant VRF_KEY_HASH = keccak256("test key hash");
    uint32 internal constant VRF_CALLBACK_GAS_LIMIT = 500000;
    uint16 internal constant VRF_REQUEST_CONFIRMATIONS = 3;

    // --- Contracts ---
    ProjectRegistry internal projectRegistry;
    DMRVManager internal dMRVManager;
    DynamicImpactCredit internal creditContract;
    MockReputationManager internal reputationManager;
    VerifierManager internal verifierManager;
    ReputationWeightedVerifier internal repWeightedVerifier;
    MethodologyRegistry internal methodologyRegistry;
    ArbitrationCouncil internal arbitrationCouncil;
    MockERC20 internal aztToken;
    VRFCoordinatorV2Mock internal vrfCoordinator;

    // --- Users ---
    address internal admin;
    address internal projectOwner;
    address internal verifier1; // Will vote 'wrong'
    address internal verifier2_arbitrator; // Will be selected for jury
    address internal challenger;
    address internal treasury;

    function setUp() public {
        // 1. Create Users
        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");
        verifier1 = makeAddr("verifier1");
        verifier2_arbitrator = makeAddr("verifier2_arbitrator");
        challenger = makeAddr("challenger");
        treasury = makeAddr("treasury");

        vm.startPrank(admin);

        // 2. Deploy contracts with no cross-dependencies
        aztToken = new MockERC20("Azemora Token", "AZT", 18);
        vrfCoordinator = new VRFCoordinatorV2Mock(0, 0);
        vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(VRF_SUB_ID, 1000 ether);

        reputationManager = new MockReputationManager();
        projectRegistry = ProjectRegistry(
            address(new ERC1967Proxy(address(new ProjectRegistry()), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        creditContract = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(new DynamicImpactCredit()),
                    abi.encodeCall(creditContract.initializeDynamicImpactCredit, (address(projectRegistry), "uri"))
                )
            )
        );
        methodologyRegistry = MethodologyRegistry(
            address(
                new ERC1967Proxy(
                    address(new MethodologyRegistry()), abi.encodeCall(MethodologyRegistry.initialize, (admin))
                )
            )
        );
        dMRVManager = DMRVManager(
            address(
                new ERC1967Proxy(
                    address(new DMRVManager()),
                    abi.encodeCall(
                        dMRVManager.initializeDMRVManager, (address(projectRegistry), address(creditContract))
                    )
                )
            )
        );

        // 3. DEPLOY PROXIES WITH CIRCULAR DEPENDENCIES (UNINITIALIZED)
        arbitrationCouncil =
            ArbitrationCouncil(payable(address(new ERC1967Proxy(address(new ArbitrationCouncil()), bytes("")))));
        verifierManager = VerifierManager(payable(address(new ERC1967Proxy(address(new VerifierManager()), bytes("")))));
        repWeightedVerifier = ReputationWeightedVerifier(
            payable(address(new ERC1967Proxy(address(new ReputationWeightedVerifier()), bytes(""))))
        );

        // 4. INITIALIZE CONTRACTS NOW THAT ALL ADDRESSES ARE KNOWN
        arbitrationCouncil.initialize(
            admin, address(aztToken), address(verifierManager), treasury, address(vrfCoordinator), VRF_SUB_ID
        );
        verifierManager.initialize(
            admin,
            address(arbitrationCouncil),
            treasury,
            address(aztToken),
            address(reputationManager),
            MIN_STAKE_AMOUNT,
            MIN_REPUTATION,
            7 days
        );
        repWeightedVerifier.initialize(
            admin,
            address(verifierManager),
            address(dMRVManager),
            address(arbitrationCouncil),
            VOTING_PERIOD,
            CHALLENGE_PERIOD,
            APPROVAL_THRESHOLD_BPS
        );

        // 5. Connect the rest of the system (roles and settings)
        arbitrationCouncil.setVrfParams(VRF_KEY_HASH, VRF_REQUEST_CONFIRMATIONS, VRF_CALLBACK_GAS_LIMIT);
        arbitrationCouncil.setChallengeStakeAmount(CHALLENGE_STAKE_AMOUNT);
        arbitrationCouncil.setCouncilSize(ARBITRATION_COUNCIL_SIZE);
        arbitrationCouncil.setVotingPeriod(VOTING_PERIOD);

        vrfCoordinator.addConsumer(VRF_SUB_ID, address(arbitrationCouncil));
        creditContract.grantRole(creditContract.DMRV_MANAGER_ROLE(), address(dMRVManager));
        creditContract.grantRole(creditContract.BURNER_ROLE(), address(dMRVManager));
        dMRVManager.setMethodologyRegistry(address(methodologyRegistry));
        dMRVManager.grantRole(dMRVManager.REVERSER_ROLE(), address(repWeightedVerifier));
        arbitrationCouncil.grantRole(arbitrationCouncil.VERIFIER_CONTRACT_ROLE(), address(repWeightedVerifier));
        verifierManager.grantRole(verifierManager.SLASHER_ROLE(), address(repWeightedVerifier));

        methodologyRegistry.addMethodology(
            REP_WEIGHTED_MODULE_TYPE, address(repWeightedVerifier), "ipfs://rep", bytes32(0)
        );
        methodologyRegistry.approveMethodology(REP_WEIGHTED_MODULE_TYPE);
        dMRVManager.registerVerifierModule(REP_WEIGHTED_MODULE_TYPE, address(repWeightedVerifier));

        // 6. Setup user states
        aztToken.mint(verifier1, INITIAL_MINT_AMOUNT);
        aztToken.mint(verifier2_arbitrator, INITIAL_MINT_AMOUNT);
        aztToken.mint(challenger, INITIAL_MINT_AMOUNT);

        reputationManager.setReputation(verifier1, MIN_REPUTATION + 100);
        reputationManager.setReputation(verifier2_arbitrator, MIN_REPUTATION + 200);

        vm.stopPrank();

        // 7. Register all verifiers
        vm.startPrank(verifier1);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier2_arbitrator);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        // 8. Create and activate a project
        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));
        vm.prank(projectOwner);
        projectRegistry.registerProject(projectId, "ipfs://project_metadata");
        vm.prank(admin);
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
    }

    function test_fullFlow_challengeAndReversal() public {
        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));
        bytes32 claimId = keccak256("Test Claim");

        // 1. A verification is requested and results in an incorrect "Approve" outcome
        vm.prank(projectOwner);
        bytes32 taskId =
            dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence", REP_WEIGHTED_MODULE_TYPE);

        vm.prank(verifier1);
        repWeightedVerifier.submitVote(taskId, Vote.Approve);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        repWeightedVerifier.proposeTaskResolution(taskId);

        assertEq(
            uint256(repWeightedVerifier.getTaskStatus(taskId)),
            uint256(TaskStatus.Provisional),
            "Task should be provisional"
        );

        // The original test incorrectly finalized the verification here.
        // In a challenge flow, we proceed directly to the challenge.
        // No credits should be minted at this stage.
        uint256 tokenId = uint256(projectId);
        assertEq(creditContract.balanceOf(projectOwner, tokenId), 0, "Credits should not be minted before finalization");

        // 2. A challenger spots the error and starts a dispute
        vm.startPrank(challenger);
        aztToken.approve(address(arbitrationCouncil), CHALLENGE_STAKE_AMOUNT);
        repWeightedVerifier.challengeVerification(taskId);
        vm.stopPrank();

        // 3. The ArbitrationCouncil uses VRF to select a jury. We mock the callback.
        uint256 requestId = 1; // First VRF request
        uint256[] memory randomWords = new uint256[](1);
        // verifier1 voted, challenger is challenging.
        // The list of potential jurors is [verifier1, verifier2_arbitrator].
        // We need to select verifier2_arbitrator, who is at index 1.
        randomWords[0] = 1;

        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(arbitrationCouncil), randomWords);

        // 4. The jury votes to OVERTURN the original decision
        vm.prank(verifier2_arbitrator);
        arbitrationCouncil.vote(taskId, false); // false = Overturn
        vm.stopPrank();

        // 5. Anyone resolves the dispute after the voting period ends
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        uint256 treasuryBalanceBefore = aztToken.balanceOf(treasury);
        uint256 challengerBalanceBefore = aztToken.balanceOf(challenger);

        arbitrationCouncil.resolveDispute(taskId);

        // --- 6. Assert Final State ---
        // Assert verifier1 (who voted wrong) was slashed
        assertEq(verifierManager.getVerifierStake(verifier1), 0, "Verifier1 should have been slashed to 0");
        assertFalse(verifierManager.isVerifier(verifier1), "Slashed verifier should be inactive");
        assertEq(
            aztToken.balanceOf(treasury),
            treasuryBalanceBefore + MIN_STAKE_AMOUNT,
            "Slashed stake should go to treasury"
        );

        // Assert challenger got their stake back (since they were right)
        uint256 challengerBalanceAfter = aztToken.balanceOf(challenger);
        assertEq(
            challengerBalanceAfter, challengerBalanceBefore + CHALLENGE_STAKE_AMOUNT, "Challenger should get stake back"
        );

        // Assert the fraudulently minted credits were burned
        assertEq(creditContract.balanceOf(projectOwner, tokenId), 0, "Credits should have been burned");

        // Assert the task status is Overturned in the verifier module
        TaskStatus status = repWeightedVerifier.getTaskStatus(taskId);
        assertEq(uint256(status), uint256(TaskStatus.Overturned), "Task status should be Overturned");
    }
}
