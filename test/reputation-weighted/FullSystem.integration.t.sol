// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Main Contracts
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";
import {DynamicImpactCredit} from "../../src/core/DynamicImpactCredit.sol";
import {ReputationManager} from "../../src/achievements/ReputationManager.sol";
import {VerifierManager} from "../../src/reputation-weighted/VerifierManager.sol";
import {ReputationWeightedVerifier} from "../../src/reputation-weighted/ReputationWeightedVerifier.sol";
import {MethodologyRegistry} from "../../src/core/MethodologyRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

// Mocks & Tokens
import {MockERC20} from "../mocks/MockERC20.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";

contract FullSystemIntegrationTest is Test {
    // --- Constants ---
    uint256 internal constant INITIAL_MINT_AMOUNT = 1_000_000 * 1e18;
    uint256 internal constant MIN_STAKE_AMOUNT = 100 * 1e18;
    uint256 internal constant MIN_REPUTATION = 50;
    uint256 internal constant UNSTAKE_LOCK_PERIOD = 7 days;
    uint256 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant APPROVAL_THRESHOLD_BPS = 5001; // 50.01%
    uint256 internal constant CHALLENGE_PERIOD = 1 days;
    uint256 internal constant CHALLENGE_STAKE = 50 * 1e18;
    uint8 internal constant ARBITRATION_COUNCIL_SIZE = 1;
    uint256 internal constant STAKE_PENALTY = 10 * 1e18; // 10 tokens
    uint256 internal constant REP_PENALTY = 10; // 10 points
    bytes32 internal constant REP_WEIGHTED_MODULE_TYPE = keccak256("REPUTATION_WEIGHTED_V1");
    uint64 internal constant VRF_SUB_ID = 1;
    bytes32 internal constant VRF_KEY_HASH = keccak256("test key hash");

    // --- Contracts ---
    ProjectRegistry internal projectRegistry;
    DMRVManager internal dMRVManager;
    DynamicImpactCredit internal creditContract;
    ReputationManager internal reputationManager;
    VerifierManager internal verifierManager;
    ReputationWeightedVerifier internal repWeightedVerifier;
    MethodologyRegistry internal methodologyRegistry;
    MockERC20 internal aztToken;
    VRFCoordinatorV2Mock internal vrfCoordinator;

    // --- Users ---
    address internal admin;
    address internal projectOwner;
    address internal verifier1;
    address internal verifier2;
    address internal verifier3_arbitrator;
    address internal challenger;
    address internal treasury;

    function setUp() public {
        // 1. Create Users
        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");
        verifier1 = makeAddr("verifier1");
        verifier2 = makeAddr("verifier2");
        verifier3_arbitrator = makeAddr("verifier3_arbitrator");
        challenger = makeAddr("challenger");
        treasury = makeAddr("treasury");

        vm.startPrank(admin);

        // 2. Deploy all contracts with CORRECT initializers
        aztToken = new MockERC20("Azemora Token", "AZT", 18);
        vrfCoordinator = new VRFCoordinatorV2Mock(0, 0);
        vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(VRF_SUB_ID, 1000 ether);

        // CORRECT: ReputationManager.initialize(address, address)
        reputationManager = ReputationManager(
            address(
                new ERC1967Proxy(
                    address(new ReputationManager()), abi.encodeCall(ReputationManager.initialize, (admin, admin))
                )
            )
        );

        // CORRECT: ProjectRegistry.initialize()
        projectRegistry = ProjectRegistry(
            address(new ERC1967Proxy(address(new ProjectRegistry()), abi.encodeCall(ProjectRegistry.initialize, ())))
        );

        // CORRECT: DynamicImpactCredit.initializeDynamicImpactCredit(address, string)
        creditContract = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(new DynamicImpactCredit()),
                    abi.encodeCall(creditContract.initializeDynamicImpactCredit, (address(projectRegistry), "uri"))
                )
            )
        );

        // CORRECT: MethodologyRegistry.initialize(address)
        methodologyRegistry = MethodologyRegistry(
            address(
                new ERC1967Proxy(
                    address(new MethodologyRegistry()), abi.encodeCall(MethodologyRegistry.initialize, (admin))
                )
            )
        );

        // CORRECT: DMRVManager.initializeDMRVManager(address, address)
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

        // CORRECT: VerifierManager.initialize(address, address, address, address, address, uint256, uint256, uint256)
        verifierManager = VerifierManager(
            address(
                new ERC1967Proxy(
                    address(new VerifierManager()),
                    abi.encodeCall(
                        VerifierManager.initialize,
                        (
                            admin,
                            admin,
                            treasury,
                            address(aztToken),
                            address(reputationManager),
                            MIN_STAKE_AMOUNT,
                            MIN_REPUTATION,
                            UNSTAKE_LOCK_PERIOD
                        )
                    )
                )
            )
        );

        // CORRECT: ReputationWeightedVerifier.initialize(...) now takes structs
        ReputationWeightedVerifier.AddressesConfig memory addrs = ReputationWeightedVerifier.AddressesConfig({
            verifierManager: address(verifierManager),
            reputationManager: address(reputationManager),
            dMRVManager: address(dMRVManager),
            treasury: treasury,
            challengeToken: address(aztToken),
            vrfCoordinator: address(vrfCoordinator)
        });

        ReputationWeightedVerifier.TimingsConfig memory timings =
            ReputationWeightedVerifier.TimingsConfig({votingPeriod: VOTING_PERIOD, challengePeriod: CHALLENGE_PERIOD});

        ReputationWeightedVerifier.ParametersConfig memory params = ReputationWeightedVerifier.ParametersConfig({
            approvalThresholdBps: APPROVAL_THRESHOLD_BPS,
            challengeStakeAmount: CHALLENGE_STAKE,
            councilSize: ARBITRATION_COUNCIL_SIZE,
            incorrectVoteStakePenalty: STAKE_PENALTY,
            incorrectVoteReputationPenalty: REP_PENALTY,
            vrfSubscriptionId: VRF_SUB_ID,
            vrfKeyHash: VRF_KEY_HASH
        });

        repWeightedVerifier = ReputationWeightedVerifier(
            address(
                new ERC1967Proxy(
                    address(new ReputationWeightedVerifier()),
                    abi.encodeCall(ReputationWeightedVerifier.initialize, (admin, addrs, timings, params))
                )
            )
        );

        // 3. Connect the system
        vrfCoordinator.addConsumer(VRF_SUB_ID, address(repWeightedVerifier));
        creditContract.grantRole(creditContract.DMRV_MANAGER_ROLE(), address(dMRVManager));
        creditContract.grantRole(creditContract.METADATA_UPDATER_ROLE(), address(dMRVManager));
        dMRVManager.setMethodologyRegistry(address(methodologyRegistry));

        methodologyRegistry.addMethodology(
            REP_WEIGHTED_MODULE_TYPE, address(repWeightedVerifier), "ipfs://rep", bytes32(0)
        );
        methodologyRegistry.approveMethodology(REP_WEIGHTED_MODULE_TYPE);
        dMRVManager.registerVerifierModule(REP_WEIGHTED_MODULE_TYPE);

        reputationManager.grantRole(reputationManager.REPUTATION_SLASHER_ROLE(), address(verifierManager));
        verifierManager.grantRole(verifierManager.SLASHER_ROLE(), address(repWeightedVerifier));
        verifierManager.revokeRole(verifierManager.SLASHER_ROLE(), admin);

        // 4. Setup user states
        aztToken.mint(verifier1, INITIAL_MINT_AMOUNT);
        aztToken.mint(verifier2, INITIAL_MINT_AMOUNT);
        aztToken.mint(verifier3_arbitrator, INITIAL_MINT_AMOUNT);
        aztToken.mint(challenger, INITIAL_MINT_AMOUNT);

        reputationManager.addReputation(verifier1, MIN_REPUTATION + 100);
        reputationManager.addReputation(verifier2, MIN_REPUTATION + 50);
        reputationManager.addReputation(verifier3_arbitrator, MIN_REPUTATION + 200);

        vm.stopPrank();

        // 5. Create and activate a project
        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));

        vm.prank(projectOwner);
        projectRegistry.registerProject(projectId, "ipfs://project_metadata");

        vm.prank(admin);
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
    }

    function test_fullFlow_successfulVerification() public {
        vm.startPrank(verifier1);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier2);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));
        bytes32 claimId = keccak256("Test Claim");

        vm.prank(projectOwner);
        bytes32 taskId =
            dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence", REP_WEIGHTED_MODULE_TYPE);

        vm.prank(verifier1);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.stopPrank();

        vm.prank(verifier2);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        repWeightedVerifier.proposeResolution(taskId);

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        repWeightedVerifier.finalizeResolution(taskId);

        assertEq(creditContract.balanceOf(projectOwner, uint256(projectId)), 1);
    }

    function test_fullFlow_successfulChallenge() public {
        vm.startPrank(verifier1);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier2);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier3_arbitrator);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));
        bytes32 claimId = keccak256("Test Claim For Challenge");

        vm.prank(projectOwner);
        bytes32 taskId =
            dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence", REP_WEIGHTED_MODULE_TYPE);

        vm.prank(verifier1);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.stopPrank();

        vm.prank(verifier2);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        repWeightedVerifier.proposeResolution(taskId);

        vm.startPrank(challenger);
        aztToken.approve(address(repWeightedVerifier), CHALLENGE_STAKE);
        uint256 requestId = repWeightedVerifier.challengeResolution(taskId, "ipfs://challenge_evidence");
        vm.stopPrank();

        // --- VRF Mock Fulfillment ---
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 0; // This will select the first eligible verifier (verifier3_arbitrator)

        // NEW, CORRECT WAY: Use prank to directly simulate the callback
        vm.prank(address(vrfCoordinator));
        repWeightedVerifier.fulfillRandomWords(requestId, randomWords);

        vm.prank(verifier3_arbitrator);
        repWeightedVerifier.castArbitrationVote(taskId, false); // false = overturn
        vm.stopPrank();

        uint256 verifier1StakeBefore = verifierManager.getVerifierStake(verifier1);
        uint256 challengerBalanceBefore = aztToken.balanceOf(challenger);

        repWeightedVerifier.resolveChallenge(taskId);

        assertEq(creditContract.balanceOf(projectOwner, uint256(projectId)), 0);

        uint256 verifier1StakeAfter = verifierManager.getVerifierStake(verifier1);
        assertLt(verifier1StakeAfter, verifier1StakeBefore);

        uint256 challengerBalanceAfter = aztToken.balanceOf(challenger);
        assertGt(challengerBalanceAfter, challengerBalanceBefore);
    }
}
