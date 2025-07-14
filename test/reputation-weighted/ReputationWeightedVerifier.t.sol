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
import {MockReputationManager} from "../mocks/MockReputationManager.sol";

// --- Mock for ArbitrationCouncil ---
contract MockArbitrationCouncil is IArbitrationCouncil {
    bytes32 public lastClaimId;
    address public lastChallenger;
    address public lastDefendant;
    bool public wasCalled;

    function createDispute(bytes32 claimId, address challenger, address defendant) external returns (bool) {
        lastClaimId = claimId;
        lastChallenger = challenger;
        lastDefendant = defendant; // The verifier module itself is the defendant
        wasCalled = true;
        return true;
    }
}

contract ReputationWeightedVerifierTest is Test {
    // --- Events to mirror for testing ---
    event TaskFinalized(bytes32 indexed taskId, bool finalOutcome, uint256 quantitativeOutcome);

    // --- Constants ---
    uint256 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant APPROVAL_THRESHOLD_BPS = 5001;
    uint256 internal constant CHALLENGE_PERIOD = 1 days;
    uint256 internal constant CHALLENGE_STAKE = 50 * 1e18;

    // --- State ---
    ReputationWeightedVerifier internal verifierModule;
    VerifierManager internal verifierManager;
    DMRVManager internal dMRVManager;
    MockReputationManager internal reputationManager;
    MethodologyRegistry internal methodologyRegistry;
    MockERC20 internal aztToken;
    ProjectRegistry internal projectRegistry;
    DynamicImpactCredit internal creditContract;
    MockArbitrationCouncil internal mockArbitrationCouncil;

    // --- Users ---
    address internal admin;
    address internal verifier1;
    address internal verifier2;
    address internal challenger;
    address internal treasury;

    bytes32 internal projectId = keccak256("p1");
    bytes32 internal claimId = keccak256("c1");
    bytes32 internal constant MODULE_TYPE = keccak256("REPUTATION_WEIGHTED_V1");

    function setUp() public {
        // --- 1. Set up users ---
        admin = makeAddr("admin");
        verifier1 = makeAddr("v1");
        verifier2 = makeAddr("v2");
        challenger = makeAddr("challenger");
        treasury = makeAddr("treasury");

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
        mockArbitrationCouncil = new MockArbitrationCouncil();

        verifierManager = VerifierManager(
            address(
                new ERC1967Proxy(
                    address(new VerifierManager()),
                    abi.encodeCall(
                        VerifierManager.initialize,
                        (
                            admin, // admin
                            address(mockArbitrationCouncil), // arbitration council
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
        verifierModule = ReputationWeightedVerifier(
            address(
                new ERC1967Proxy(
                    address(new ReputationWeightedVerifier()),
                    abi.encodeCall(
                        ReputationWeightedVerifier.initialize,
                        (
                            admin,
                            address(verifierManager),
                            address(dMRVManager),
                            address(mockArbitrationCouncil),
                            VOTING_PERIOD,
                            CHALLENGE_PERIOD,
                            APPROVAL_THRESHOLD_BPS
                        )
                    )
                )
            )
        );

        // --- 5. Grant all necessary roles ---
        creditContract.grantRole(creditContract.DMRV_MANAGER_ROLE(), address(dMRVManager));
        creditContract.grantRole(creditContract.BURNER_ROLE(), address(dMRVManager));
        dMRVManager.grantRole(dMRVManager.REVERSER_ROLE(), address(verifierModule));
        verifierModule.grantRole(verifierModule.ARBITRATION_COUNCIL_ROLE(), address(mockArbitrationCouncil));
        verifierManager.grantRole(verifierManager.SLASHER_ROLE(), address(verifierModule));

        methodologyRegistry.addMethodology(MODULE_TYPE, address(verifierModule), "ipfs://", bytes32(0));
        methodologyRegistry.approveMethodology(MODULE_TYPE);
        dMRVManager.addVerifierModule(MODULE_TYPE);
        projectRegistry.registerProject(projectId, "ipfs://project");
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        vm.stopPrank();

        // --- 6. Set up user states ---
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
        // We must start the task via the dMRVManager to correctly simulate the flow.
        // This ensures the dMRVManager has a record of the pending claim.
        // Bypassing it and calling the verifierModule directly (as before) causes
        // the dMRVManager to revert on fulfillment because it has no record of the claim.
        vm.prank(admin); // Any user can request verification
        uint256 requestedAmount = 100e18; // Standard request for tests
        taskId = dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence", requestedAmount, MODULE_TYPE);
    }

    /*//////////////////////////////////////////////////////////////
                           NEW OPTIMISTIC FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_flow_optimisticHappyPath() public {
        bytes32 taskId = _startTask();

        // No voting occurs. We just fast-forward past the challenge period.
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        // We expect dMRVManager to be called with a successful outcome (100%).
        bytes memory expectedData = abi.encode(100, false, bytes32(0), "ipfs://evidence");
        vm.expectCall(
            address(dMRVManager),
            abi.encodeWithSelector(dMRVManager.fulfillVerification.selector, projectId, claimId, expectedData)
        );

        // We also expect the new event signature
        vm.expectEmit(true, true, true, false);
        emit TaskFinalized(taskId, true, 100);

        verifierModule.finalizeVerification(taskId);

        TaskStatus finalStatus = verifierModule.getTaskStatus(taskId);
        assertEq(uint256(finalStatus), uint256(TaskStatus.Finalized));
    }

    function test_flow_optimisticChallengePath() public {
        bytes32 taskId = _startTask();

        // Immediately challenge the optimistic assumption.
        vm.startPrank(challenger);
        aztToken.approve(address(mockArbitrationCouncil), CHALLENGE_STAKE);

        // We expect the module to call the arbitration council to create a dispute.
        vm.expectCall(
            address(mockArbitrationCouncil),
            abi.encodeWithSelector(
                mockArbitrationCouncil.createDispute.selector, taskId, challenger, address(verifierModule)
            )
        );
        verifierModule.challengeVerification(taskId);
        vm.stopPrank();

        // Assert the state is now 'Challenged'.
        assertTrue(mockArbitrationCouncil.wasCalled());
        assertEq(mockArbitrationCouncil.lastClaimId(), taskId);

        TaskStatus status = verifierModule.getTaskStatus(taskId);
        assertEq(uint256(status), uint256(TaskStatus.Challenged));
    }

    function test_finalizeVerification_RevertsIfChallengePeriodNotOver() public {
        bytes32 taskId = _startTask();

        // We are still within the challenge period.
        vm.expectRevert(ReputationWeightedVerifier__ChallengePeriodNotOver.selector);
        verifierModule.finalizeVerification(taskId);
    }

    function test_challengeVerification_RevertsIfChallengePeriodOver() public {
        bytes32 taskId = _startTask();

        // Fast-forward past the challenge period.
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(challenger);
        vm.expectRevert(ReputationWeightedVerifier__ChallengePeriodOver.selector);
        verifierModule.challengeVerification(taskId);
    }

    function test_processArbitrationResult_succeeds() public {
        bytes32 taskId = _startTask();

        // 1. Challenge the task to move it to the correct state
        vm.startPrank(challenger);
        aztToken.approve(address(mockArbitrationCouncil), CHALLENGE_STAKE);
        verifierModule.challengeVerification(taskId);
        vm.stopPrank();

        // 2. Simulate the call from the ArbitrationCouncil
        uint256 finalAmount = 85; // e.g., council decided 85% is the correct outcome
        bytes memory expectedData = abi.encode(finalAmount, true, taskId, "ipfs://evidence");

        vm.expectCall(
            address(dMRVManager),
            abi.encodeWithSelector(dMRVManager.fulfillVerification.selector, projectId, claimId, expectedData)
        );

        vm.prank(address(mockArbitrationCouncil)); // Must be called by the council
        verifierModule.processArbitrationResult(taskId, finalAmount);

        // 3. Assert final state
        TaskStatus status = verifierModule.getTaskStatus(taskId);
        assertEq(uint256(status), uint256(TaskStatus.Finalized));
    }

    function test_revert_if_processArbitrationResult_from_unauthorized() public {
        bytes32 taskId = _startTask();

        // Challenge to put in correct state
        vm.startPrank(challenger);
        aztToken.approve(address(mockArbitrationCouncil), CHALLENGE_STAKE);
        verifierModule.challengeVerification(taskId);
        vm.stopPrank();

        // Attempt to call from an unauthorized address
        vm.prank(admin);
        vm.expectRevert(ReputationWeightedVerifier__UnauthorizedCaller.selector);
        verifierModule.processArbitrationResult(taskId, 50);
    }

    function test_revert_if_startVerificationTask_from_unauthorized_caller() public {
        vm.prank(admin); // Use any address that is not the dMRVManager
        vm.expectRevert("Only dMRVManager can start tasks");
        verifierModule.startVerificationTask(projectId, claimId, "ipfs://evidence");
    }
}
