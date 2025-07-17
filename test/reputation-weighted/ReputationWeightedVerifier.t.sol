// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    ReputationWeightedVerifier,
    TaskStatus,
    Vote,
    ReputationWeightedVerifier__ChallengePeriodNotOver,
    ReputationWeightedVerifier__ChallengePeriodOver,
    ReputationWeightedVerifier__UnauthorizedCaller
} from "../../src/reputation-weighted/ReputationWeightedVerifier.sol";
import {VerifierManager} from "../../src/reputation-weighted/VerifierManager.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DynamicImpactCredit} from "../../src/core/DynamicImpactCredit.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {MethodologyRegistry} from "../../src/core/MethodologyRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import {IArbitrationCouncil} from "../../src/governance/interfaces/IArbitrationCouncil.sol";
import {IVerifierManager} from "../../src/reputation-weighted/interfaces/IVerifierManager.sol";
import {IDMRVManager} from "../../src/core/interfaces/IDMRVManager.sol";
import {IVerificationData} from "../../src/core/interfaces/IVerificationData.sol";
import {MockReputationManager} from "../mocks/MockReputationManager.sol";

// --- Mock for ArbitrationCouncil ---
// A simple mock that only needs to implement the interface for vm.expectCall to work.
contract MockArbitrationCouncil is IArbitrationCouncil {
    function createDispute(bytes32, address, bytes calldata) external override returns (bool) {
        return true;
    }
}

contract ReputationWeightedVerifierTest is Test {
    // --- Events to mirror for testing ---
    event TaskFinalized(bytes32 indexed taskId, bool finalOutcome, uint256 quantitativeOutcome);
    event TaskChallenged(bytes32 indexed taskId, address indexed challenger);

    // --- Constants ---
    uint256 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant APPROVAL_THRESHOLD_BPS = 5001;
    uint256 internal constant CHALLENGE_PERIOD = 1 days;
    uint256 internal constant CHALLENGE_STAKE = 50 * 1e18;
    uint256 internal constant KEEPER_BOUNTY = 1 ether;

    // --- State ---
    ReputationWeightedVerifier internal verifier;
    VerifierManager internal verifierManager;
    DMRVManager internal dMRVManager;
    MockReputationManager internal reputationManager;
    MethodologyRegistry internal methodologyRegistry;
    MockERC20 internal aztToken;
    ProjectRegistry internal projectRegistry;
    DynamicImpactCredit internal creditContract;
    MockArbitrationCouncil internal arbitrationCouncil;

    // --- Users ---
    address internal admin;
    address internal verifier1;
    address internal verifier2;
    address internal challenger;
    address internal treasury;
    address internal keeper;
    address internal user;

    bytes32 internal projectId = keccak256("p1");
    bytes32 internal claimId = keccak256("c1");
    bytes32 internal constant MODULE_TYPE = keccak256("REPUTATION_WEIGHTED_V1");

    // Keys for signing
    uint256 internal challengerPrivateKey = 0x456;

    bytes32 internal constant PROJECT_ID = keccak256("project_1");
    bytes32 internal constant CLAIM_ID = keccak256("claim_1");
    bytes32 internal constant TASK_ID = keccak256(abi.encodePacked(PROJECT_ID, CLAIM_ID, uint256(0)));

    function setUp() public {
        // --- 1. Set up users ---
        admin = makeAddr("admin");
        verifier1 = makeAddr("v1");
        verifier2 = makeAddr("v2");
        challenger = vm.addr(challengerPrivateKey);
        treasury = makeAddr("treasury");
        keeper = makeAddr("keeper");
        user = makeAddr("user");

        vm.startPrank(admin);

        // --- 2. Deploy core dependencies (Tokens, Registries) ---
        aztToken = new MockERC20("AZT", "AZT", 18);
        projectRegistry = ProjectRegistry(
            address(new ERC1967Proxy(address(new ProjectRegistry()), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        methodologyRegistry = MethodologyRegistry(
            address(
                new ERC1967Proxy(
                    address(new MethodologyRegistry()), abi.encodeCall(MethodologyRegistry.initialize, (admin))
                )
            )
        );
        creditContract = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(new DynamicImpactCredit()),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(projectRegistry), "uri"))
                )
            )
        );

        // --- 3. Deploy Managers & Mocks ---
        reputationManager = new MockReputationManager();
        arbitrationCouncil = new MockArbitrationCouncil();

        verifierManager = VerifierManager(
            address(
                new ERC1967Proxy(
                    address(new VerifierManager()),
                    abi.encodeCall(
                        VerifierManager.initialize,
                        (
                            admin, // admin
                            address(arbitrationCouncil), // arbitration council
                            treasury,
                            address(aztToken),
                            address(reputationManager),
                            100 * 1e18, // min stake
                            50, // min rep
                            7 days
                        )
                    )
                )
            )
        );

        dMRVManager = DMRVManager(
            address(
                new ERC1967Proxy(
                    address(new DMRVManager()),
                    abi.encodeCall(
                        DMRVManager.initializeDMRVManager,
                        (address(projectRegistry), address(creditContract), address(methodologyRegistry))
                    )
                )
            )
        );

        // --- 4. Deploy the main module under test ---
        verifier = ReputationWeightedVerifier(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new ReputationWeightedVerifier()),
                        abi.encodeCall(
                            ReputationWeightedVerifier.initialize,
                            (
                                admin,
                                address(verifierManager),
                                address(dMRVManager),
                                address(arbitrationCouncil),
                                VOTING_PERIOD,
                                CHALLENGE_PERIOD,
                                APPROVAL_THRESHOLD_BPS
                            )
                        )
                    )
                )
            )
        );

        // --- 5. Configure bounty and fund the contract ---
        verifier.setKeeperBounty(KEEPER_BOUNTY);
        vm.deal(address(verifier), 5 ether); // Fund with 5 ETH

        // --- 6. Grant all necessary roles ---
        creditContract.grantRole(creditContract.DMRV_MANAGER_ROLE(), address(dMRVManager));
        creditContract.grantRole(creditContract.BURNER_ROLE(), address(dMRVManager));
        dMRVManager.grantRole(dMRVManager.REVERSER_ROLE(), address(verifier));
        verifier.grantRole(verifier.ARBITRATION_COUNCIL_ROLE(), address(arbitrationCouncil));
        verifierManager.grantRole(verifierManager.SLASHER_ROLE(), address(verifier));

        methodologyRegistry.addMethodology(MODULE_TYPE, address(verifier), "ipfs://", bytes32(0));
        methodologyRegistry.approveMethodology(MODULE_TYPE);
        dMRVManager.addVerifierModule(MODULE_TYPE);
        projectRegistry.registerProject(projectId, "ipfs://project");
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        vm.stopPrank();

        // --- 7. Set up user states ---
        aztToken.mint(verifier1, 100 * 1e18);
        aztToken.mint(verifier2, 100 * 1e18);
        aztToken.mint(challenger, CHALLENGE_STAKE);

        reputationManager.setReputation(verifier1, 100);
        reputationManager.setReputation(verifier2, 75);

        // --- 7. Register verifiers ---
        vm.startPrank(verifier1);
        aztToken.approve(address(verifierManager), 100 * 1e18);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier2);
        aztToken.approve(address(verifierManager), 100 * 1e18);
        verifierManager.register();
        vm.stopPrank();
    }

    function _startTask() internal returns (bytes32 taskId) {
        vm.prank(admin);
        uint256 requestedAmount = 100e18;
        taskId = dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence", requestedAmount, MODULE_TYPE);
    }

    function _getChallengeSignature(bytes32 taskId, address verifierModule, uint256 privateKey)
        internal
        pure
        returns (bytes memory)
    {
        // For the purpose of testing the verifier, we only need to pass a correctly encoded signature.
        // The actual cryptographic validity is tested in the ArbitrationCouncil tests.
        // We are creating a dummy signature here.
        bytes32 digest = keccak256(abi.encodePacked(taskId, verifierModule));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                           OPTIMISTIC FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_flow_optimisticHappyPath() public {
        bytes32 taskId = _startTask();

        // No voting occurs. We just fast-forward past the challenge period.
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        // We expect dMRVManager to be called with a successful outcome (100%).
        IVerificationData.VerificationResult memory expectedResult = IVerificationData.VerificationResult({
            quantitativeOutcome: 100,
            wasArbitrated: false,
            arbitrationDisputeId: 0,
            credentialCID: "ipfs://evidence"
        });
        vm.expectCall(
            address(dMRVManager), abi.encodeCall(dMRVManager.fulfillVerification, (projectId, claimId, expectedResult))
        );

        vm.prank(keeper);
        verifier.finalizeVerification(taskId);

        TaskStatus finalStatus = verifier.getTaskStatus(taskId);
        assertEq(uint256(finalStatus), uint256(TaskStatus.Finalized));
    }

    function test_flow_optimisticChallengePath() public {
        bytes32 taskId = _startTask();

        // Immediately challenge the optimistic assumption.
        vm.startPrank(challenger);
        aztToken.approve(address(arbitrationCouncil), CHALLENGE_STAKE);

        bytes memory signature = _getChallengeSignature(taskId, address(verifier), challengerPrivateKey);

        // We expect the module to call the arbitration council to create a dispute.
        vm.expectCall(
            address(arbitrationCouncil),
            abi.encodeWithSelector(IArbitrationCouncil.createDispute.selector, taskId, address(verifier), signature)
        );
        verifier.challengeVerification(taskId, signature);
        vm.stopPrank();

        // Assert the state is now 'Challenged'.
        TaskStatus status = verifier.getTaskStatus(taskId);
        assertEq(uint256(status), uint256(TaskStatus.Challenged));
    }

    function test_finalizeVerification_RevertsIfChallengePeriodNotOver() public {
        bytes32 taskId = _startTask();

        // We are still within the challenge period.
        vm.expectRevert(ReputationWeightedVerifier__ChallengePeriodNotOver.selector);
        verifier.finalizeVerification(taskId);
    }

    function test_challengeVerification_RevertsIfChallengePeriodOver() public {
        bytes32 taskId = _startTask();

        // Fast-forward past the challenge period.
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(challenger);
        bytes memory signature = _getChallengeSignature(taskId, address(verifier), challengerPrivateKey);
        vm.expectRevert(ReputationWeightedVerifier__ChallengePeriodOver.selector);
        verifier.challengeVerification(taskId, signature);
    }

    function test_processArbitrationResult_succeeds() public {
        bytes32 taskId = _startTask();

        // 1. Challenge the task to move it to the correct state
        vm.startPrank(challenger);
        aztToken.approve(address(arbitrationCouncil), CHALLENGE_STAKE);
        bytes memory signature = _getChallengeSignature(taskId, address(verifier), challengerPrivateKey);
        verifier.challengeVerification(taskId, signature);
        vm.stopPrank();

        // 2. Simulate the call from the ArbitrationCouncil
        uint256 finalAmount = 85; // e.g., council decided 85% is the correct outcome
        IVerificationData.VerificationResult memory expectedResult = IVerificationData.VerificationResult({
            quantitativeOutcome: finalAmount,
            wasArbitrated: true,
            arbitrationDisputeId: uint256(taskId),
            credentialCID: "ipfs://evidence"
        });

        vm.expectCall(
            address(dMRVManager), abi.encodeCall(dMRVManager.fulfillVerification, (projectId, claimId, expectedResult))
        );

        vm.prank(address(arbitrationCouncil)); // Must be called by the council
        verifier.processArbitrationResult(taskId, finalAmount);

        // 3. Assert final state
        TaskStatus status = verifier.getTaskStatus(taskId);
        assertEq(uint256(status), uint256(TaskStatus.Finalized));
    }

    function test_revert_if_processArbitrationResult_from_unauthorized() public {
        bytes32 taskId = _startTask();

        // Challenge to put in correct state
        vm.startPrank(challenger);
        aztToken.approve(address(arbitrationCouncil), CHALLENGE_STAKE);
        bytes memory signature = _getChallengeSignature(taskId, address(verifier), challengerPrivateKey);
        verifier.challengeVerification(taskId, signature);
        vm.stopPrank();

        // Attempt to call from an unauthorized address
        vm.prank(admin);
        vm.expectRevert(ReputationWeightedVerifier__UnauthorizedCaller.selector);
        verifier.processArbitrationResult(taskId, 50);
    }

    function test_revert_if_startVerificationTask_from_unauthorized_caller() public {
        vm.prank(admin); // Use any address that is not the dMRVManager
        vm.expectRevert("Only dMRVManager can start tasks");
        verifier.startVerificationTask(projectId, claimId, "ipfs://evidence");
    }

    function test_finalizeVerification_creditsKeeperBounty() public {
        bytes32 taskId = _startTask();
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        uint256 bountyBalanceBefore = verifier.keeperBounties(keeper);

        vm.prank(keeper);
        verifier.finalizeVerification(taskId);

        uint256 bountyBalanceAfter = verifier.keeperBounties(keeper);

        assertEq(
            bountyBalanceAfter - bountyBalanceBefore, KEEPER_BOUNTY, "Keeper did not receive correct bounty credit"
        );
    }
}
