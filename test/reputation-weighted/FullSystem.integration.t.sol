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
    // --- Test Data Struct ---
    // Group test variables into a struct to reduce stack depth.
    struct TestData {
        bytes32 projectId;
        bytes32 claimId;
        uint256 originalRequestedAmount;
        bytes32 taskId;
        uint256 vote2;
        uint256 vote3;
    }

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
    address internal verifier3_arbitrator; // Will also be selected
    address internal challenger;
    address internal treasury;

    function setUp() public {
        // 1. Create Users
        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");
        verifier1 = makeAddr("verifier1");
        verifier2_arbitrator = makeAddr("verifier2_arbitrator");
        verifier3_arbitrator = makeAddr("verifier3_arbitrator");
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
        arbitrationCouncil.setCouncilSize(2);
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
        aztToken.mint(verifier3_arbitrator, INITIAL_MINT_AMOUNT);
        aztToken.mint(challenger, INITIAL_MINT_AMOUNT);

        reputationManager.setReputation(verifier1, MIN_REPUTATION + 50); // 100 total
        reputationManager.setReputation(verifier2_arbitrator, MIN_REPUTATION + 150); // 200 total
        reputationManager.setReputation(verifier3_arbitrator, MIN_REPUTATION + 250); // 300 total

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

        vm.startPrank(verifier3_arbitrator);
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

    function test_fullFlow_quantitativeArbitration() public {
        TestData memory data;

        data.projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));
        data.claimId = keccak256("Test Claim");
        data.originalRequestedAmount = 1000 * 1e18; // The project requests 1000 credits.

        // 1. A verification is requested optimistically.
        vm.prank(projectOwner);
        data.taskId = dMRVManager.requestVerification(
            data.projectId, data.claimId, "ipfs://evidence", data.originalRequestedAmount, REP_WEIGHTED_MODULE_TYPE
        );

        // 2. A challenger starts a dispute.
        vm.startPrank(challenger);
        aztToken.approve(address(arbitrationCouncil), CHALLENGE_STAKE_AMOUNT);
        repWeightedVerifier.challengeVerification(data.taskId);
        vm.stopPrank();

        // 3. The ArbitrationCouncil uses VRF to select a jury.
        // Use a tight scope for VRF variables as they are not needed later.
        {
            uint256 requestId = 1;
            uint256[] memory randomWords = new uint256[](2);
            randomWords[0] = 1;
            randomWords[1] = 2;
            vm.prank(admin);
            vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(arbitrationCouncil), randomWords);
        }

        // 4. The jurors cast quantitative votes.
        data.vote2 = 90;
        data.vote3 = 96;
        vm.prank(verifier2_arbitrator);
        arbitrationCouncil.vote(data.taskId, data.vote2);
        vm.stopPrank();
        vm.prank(verifier3_arbitrator);
        arbitrationCouncil.vote(data.taskId, data.vote3);
        vm.stopPrank();

        // 5. Anyone resolves the dispute after the voting period ends.
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // --- 6. Calculate Expected Outcome ---
        uint256 quantitativeOutcome;
        uint256 expectedMintAmount;
        {
            uint256 rep2 = reputationManager.getReputation(verifier2_arbitrator);
            uint256 rep3 = reputationManager.getReputation(verifier3_arbitrator);
            quantitativeOutcome = ((data.vote2 * rep2) + (data.vote3 * rep3)) / (rep2 + rep3);

            expectedMintAmount = (data.originalRequestedAmount * quantitativeOutcome) / 100;
        }

        arbitrationCouncil.resolveDispute(data.taskId, bytes32(0));

        // The callback to ReputationWeightedVerifier now happens automatically
        // inside resolveDispute. The keeper simulation is no longer needed.

        // --- 7. Assert Final State ---
        uint256 tokenId = uint256(data.projectId);
        assertEq(
            creditContract.balanceOf(projectOwner, tokenId),
            expectedMintAmount,
            "The precise, reputation-weighted amount of credits should have been minted"
        );

        TaskStatus status = repWeightedVerifier.getTaskStatus(data.taskId);
        assertEq(uint256(status), uint256(TaskStatus.Finalized), "Task status should be Finalized");
    }
}
