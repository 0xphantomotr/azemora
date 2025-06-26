// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationWeightedVerifier, TaskStatus} from "../../src/reputation-weighted/ReputationWeightedVerifier.sol";
import {VerifierManager} from "../../src/reputation-weighted/VerifierManager.sol";
import {ReputationManager} from "../../src/achievements/ReputationManager.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DynamicImpactCredit} from "../../src/core/DynamicImpactCredit.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {MethodologyRegistry} from "../../src/core/MethodologyRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

contract ReputationWeightedVerifierTest is Test {
    // --- Constants ---
    uint256 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant APPROVAL_THRESHOLD_BPS = 5001;
    uint256 internal constant CHALLENGE_PERIOD = 1 days;
    uint256 internal constant CHALLENGE_STAKE = 50 * 1e18;
    uint8 internal constant ARBITRATION_COUNCIL_SIZE = 1;
    uint256 internal constant STAKE_PENALTY = 10 * 1e18;
    uint256 internal constant REP_PENALTY = 10;
    uint256 internal constant MIN_STAKE_AMOUNT = 100 * 1e18;
    uint256 internal constant MIN_REPUTATION = 50;

    // --- State ---
    ReputationWeightedVerifier internal verifierModule;
    VerifierManager internal verifierManager;
    ReputationManager internal reputationManager;
    DMRVManager internal dMRVManager;
    MethodologyRegistry internal methodologyRegistry;
    MockERC20 internal aztToken;
    ProjectRegistry internal projectRegistry;
    DynamicImpactCredit internal creditContract;

    // --- Users ---
    address internal admin;
    address internal verifier1;
    address internal verifier2;
    address internal challenger;
    address internal arbitrator;
    address internal treasury;

    bytes32 internal projectId = keccak256("p1");
    bytes32 internal claimId = keccak256("c1");
    bytes32 internal taskId;

    function setUp() public {
        // --- 1. Set up users ---
        admin = makeAddr("admin");
        verifier1 = makeAddr("v1");
        verifier2 = makeAddr("v2");
        challenger = makeAddr("challenger");
        arbitrator = makeAddr("arbitrator");
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
                    address(new MethodologyRegistry()), abi.encodeCall(MethodologyRegistry.initialize, admin)
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

        // --- 3. Deploy Managers ---
        reputationManager = ReputationManager(
            address(
                new ERC1967Proxy(
                    address(new ReputationManager()),
                    abi.encodeCall(ReputationManager.initialize, (admin, admin)) // updater, slasher
                )
            )
        );

        verifierManager = VerifierManager(
            address(
                new ERC1967Proxy(
                    address(new VerifierManager()),
                    abi.encodeCall(
                        VerifierManager.initialize,
                        (
                            admin, // admin
                            admin, // slasher -> Temporarily set to admin
                            treasury,
                            address(aztToken),
                            address(reputationManager),
                            MIN_STAKE_AMOUNT,
                            MIN_REPUTATION,
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
                        DMRVManager.initializeDMRVManager, (address(projectRegistry), address(creditContract))
                    )
                )
            )
        );

        // --- 4. Deploy the main module under test ---
        ReputationWeightedVerifier.AddressesConfig memory addrs = ReputationWeightedVerifier.AddressesConfig({
            verifierManager: address(verifierManager),
            reputationManager: address(reputationManager),
            dMRVManager: address(dMRVManager),
            treasury: treasury,
            challengeToken: address(aztToken)
        });

        ReputationWeightedVerifier.TimingsConfig memory timings =
            ReputationWeightedVerifier.TimingsConfig({votingPeriod: VOTING_PERIOD, challengePeriod: CHALLENGE_PERIOD});

        ReputationWeightedVerifier.ParametersConfig memory params = ReputationWeightedVerifier.ParametersConfig({
            approvalThresholdBps: APPROVAL_THRESHOLD_BPS,
            challengeStakeAmount: CHALLENGE_STAKE,
            councilSize: ARBITRATION_COUNCIL_SIZE,
            incorrectVoteStakePenalty: STAKE_PENALTY,
            incorrectVoteReputationPenalty: REP_PENALTY
        });

        verifierModule = ReputationWeightedVerifier(
            address(
                new ERC1967Proxy(
                    address(new ReputationWeightedVerifier()),
                    abi.encodeCall(ReputationWeightedVerifier.initialize, (admin, addrs, timings, params))
                )
            )
        );

        // --- 5. Grant all necessary roles ---
        creditContract.grantRole(creditContract.DMRV_MANAGER_ROLE(), address(dMRVManager));
        dMRVManager.grantRole(keccak256("VERIFIER_MODULE_ROLE"), address(verifierModule));
        reputationManager.grantRole(reputationManager.REPUTATION_SLASHER_ROLE(), address(verifierManager));

        // Grant the slasher role to the module and revoke it from the temporary holder (admin)
        verifierManager.grantRole(verifierManager.SLASHER_ROLE(), address(verifierModule));
        verifierManager.revokeRole(verifierManager.SLASHER_ROLE(), admin);

        // --- 5a. Register the module with the dMRVManager ---
        dMRVManager.setMethodologyRegistry(address(methodologyRegistry));
        bytes32 moduleType = keccak256("REPUTATION_WEIGHTED_V1");
        methodologyRegistry.addMethodology(
            moduleType, address(verifierModule), "ipfs://schema", keccak256("schema_hash")
        );
        methodologyRegistry.approveMethodology(moduleType);
        dMRVManager.registerVerifierModule(moduleType);
        projectRegistry.registerProject(projectId, "ipfs://project");
        projectRegistry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);

        vm.stopPrank();

        // --- 6. Set up user states ---
        aztToken.mint(verifier1, MIN_STAKE_AMOUNT);
        aztToken.mint(verifier2, MIN_STAKE_AMOUNT);
        aztToken.mint(challenger, CHALLENGE_STAKE);
        aztToken.mint(arbitrator, MIN_STAKE_AMOUNT);

        vm.startPrank(admin);
        reputationManager.addReputation(verifier1, 100);
        reputationManager.addReputation(verifier2, 75);
        reputationManager.addReputation(arbitrator, 100);
        vm.stopPrank();

        // --- 7. Register verifiers ---
        vm.startPrank(verifier1);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier2);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(arbitrator);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        // --- 8. Start a task for tests ---
        vm.prank(admin); // A project owner (admin in this case) requests verification
        taskId = dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence", moduleType);
    }

    function test_submitVote() public {
        vm.prank(verifier1);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        (uint256 approveVotes, uint256 rejectVotes) = verifierModule.getTaskVotes(taskId);
        assertEq(approveVotes, 100);
        assertEq(rejectVotes, 0);
    }

    function test_proposeAndFinalizeResolution_succeeds_withApproval() public {
        vm.prank(verifier1); // 100 rep
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.prank(verifier2); // 75 rep
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        verifierModule.proposeResolution(taskId);

        (,,,, TaskStatus status, bool provisionalOutcome,,,) = verifierModule.tasks(taskId);
        assertEq(uint256(status), uint256(TaskStatus.Provisional));
        assertTrue(provisionalOutcome);

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        bytes memory expectedData = abi.encode(uint256(1), false, bytes32(0), "ipfs://verified");
        vm.expectCall(
            address(dMRVManager),
            abi.encodeWithSelector(DMRVManager.fulfillVerification.selector, projectId, claimId, expectedData)
        );
        verifierModule.finalizeResolution(taskId);

        (,,,, TaskStatus finalStatus,,,,) = verifierModule.tasks(taskId);
        assertEq(uint256(finalStatus), uint256(TaskStatus.Resolved));
    }

    function test_revert_finalizeResolution_ifChallengePeriodNotOver() public {
        vm.prank(verifier1);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        verifierModule.proposeResolution(taskId);

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("ReputationWeightedVerifier__ChallengePeriodNotOver()")))
        );
        verifierModule.finalizeResolution(taskId);
    }

    function test_fullChallengeFlow() public {
        vm.prank(verifier1);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject); // 100 reject
        vm.prank(verifier2);
        verifierModule.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve); // 75 approve

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.prank(verifier1); // Have a specific user propose
        verifierModule.proposeResolution(taskId);

        vm.startPrank(challenger);
        aztToken.approve(address(verifierModule), CHALLENGE_STAKE);
        verifierModule.challengeResolution(taskId, "ipfs://challenge");
        vm.stopPrank();

        (,,,, TaskStatus status,,,,) = verifierModule.tasks(taskId);
        assertEq(uint256(status), uint256(TaskStatus.Challenged));

        vm.startPrank(arbitrator); // Is on council because they didn't vote
        verifierModule.castArbitrationVote(taskId, false); // false = overturn
        vm.stopPrank();

        uint256 v1StakeBefore = verifierManager.getVerifierStake(verifier1);
        uint256 challengerBalanceBefore = aztToken.balanceOf(challenger);

        bytes memory expectedData = abi.encode(uint256(1), false, bytes32(0), "ipfs://verified");
        vm.expectCall(
            address(dMRVManager),
            abi.encodeWithSelector(DMRVManager.fulfillVerification.selector, projectId, claimId, expectedData)
        );
        verifierModule.resolveChallenge(taskId);

        uint256 v1StakeAfter = verifierManager.getVerifierStake(verifier1);
        uint256 challengerBalanceAfter = aztToken.balanceOf(challenger);

        assertLt(v1StakeAfter, v1StakeBefore, "v1 stake should be slashed");
        assertEq(v1StakeBefore - v1StakeAfter, STAKE_PENALTY, "slash amount incorrect");
        assertGt(challengerBalanceAfter, challengerBalanceBefore, "challenger should be rewarded");
    }
}
