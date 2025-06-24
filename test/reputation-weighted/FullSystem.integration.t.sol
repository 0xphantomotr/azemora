// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Main Contracts
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {DMRVManager, DMRVManager__ProjectNotActive} from "../../src/core/dMRVManager.sol";
import {DynamicImpactCredit} from "../../src/core/DynamicImpactCredit.sol";
import {ReputationManager} from "../../src/achievements/ReputationManager.sol";
import {VerifierManager} from "../../src/reputation-weighted/VerifierManager.sol";
import {ReputationWeightedVerifier} from "../../src/reputation-weighted/ReputationWeightedVerifier.sol";

// Mocks & Tokens
import {MockERC20} from "../mocks/MockERC20.sol";

contract FullSystemIntegrationTest is Test {
    // --- Constants ---
    uint256 internal constant INITIAL_MINT_AMOUNT = 1_000_000 * 1e18;
    uint256 internal constant MIN_STAKE_AMOUNT = 100 * 1e18;
    uint256 internal constant MIN_REPUTATION = 50;
    uint256 internal constant UNSTAKE_LOCK_PERIOD = 7 days;
    uint256 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant APPROVAL_THRESHOLD_BPS = 5001; // 50.01%
    bytes32 internal constant REP_WEIGHTED_MODULE_TYPE = keccak256("REPUTATION_WEIGHTED_V1");

    // --- Contracts ---
    ProjectRegistry internal projectRegistry;
    DMRVManager internal dMRVManager;
    DynamicImpactCredit internal creditContract;
    ReputationManager internal reputationManager;
    VerifierManager internal verifierManager;
    ReputationWeightedVerifier internal repWeightedVerifier;
    MockERC20 internal aztToken;

    // --- Users ---
    address internal admin;
    address internal projectOwner;
    address internal verifier1;
    address internal verifier2;
    address internal treasury;

    function setUp() public {
        // 1. Create Users
        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");
        verifier1 = makeAddr("verifier1");
        verifier2 = makeAddr("verifier2");
        treasury = makeAddr("treasury");

        vm.startPrank(admin);

        // 2. Deploy all contracts
        aztToken = new MockERC20("Azemora Token", "AZT", 18);

        ReputationManager rmImpl = new ReputationManager();
        reputationManager = ReputationManager(
            address(
                new ERC1967Proxy(
                    address(rmImpl),
                    abi.encodeWithSelector(ReputationManager.initialize.selector, address(0), address(0))
                )
            )
        );

        ProjectRegistry prImpl = new ProjectRegistry();
        projectRegistry = ProjectRegistry(
            address(new ERC1967Proxy(address(prImpl), abi.encodeWithSelector(ProjectRegistry.initialize.selector)))
        );

        DynamicImpactCredit dicImpl = new DynamicImpactCredit();
        creditContract = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(dicImpl),
                    abi.encodeWithSelector(
                        dicImpl.initializeDynamicImpactCredit.selector, address(projectRegistry), "ipfs://contract_uri"
                    )
                )
            )
        );

        DMRVManager dmrvImpl = new DMRVManager();
        dMRVManager = DMRVManager(
            address(
                new ERC1967Proxy(
                    address(dmrvImpl),
                    abi.encodeWithSelector(
                        DMRVManager.initializeDMRVManager.selector, address(projectRegistry), address(creditContract)
                    )
                )
            )
        );

        VerifierManager vmImpl = new VerifierManager();
        verifierManager = VerifierManager(
            address(
                new ERC1967Proxy(
                    address(vmImpl),
                    abi.encodeWithSelector(
                        VerifierManager.initialize.selector,
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
        );

        ReputationWeightedVerifier rwvImpl = new ReputationWeightedVerifier();
        repWeightedVerifier = ReputationWeightedVerifier(
            address(
                new ERC1967Proxy(
                    address(rwvImpl),
                    abi.encodeWithSelector(
                        ReputationWeightedVerifier.initialize.selector,
                        admin,
                        address(verifierManager),
                        address(reputationManager),
                        address(dMRVManager),
                        VOTING_PERIOD,
                        APPROVAL_THRESHOLD_BPS
                    )
                )
            )
        );

        // 3. Connect the system
        creditContract.grantRole(creditContract.DMRV_MANAGER_ROLE(), address(dMRVManager));
        creditContract.grantRole(creditContract.METADATA_UPDATER_ROLE(), address(dMRVManager));
        dMRVManager.registerVerifierModule(REP_WEIGHTED_MODULE_TYPE, address(repWeightedVerifier));
        reputationManager.grantRole(reputationManager.REPUTATION_UPDATER_ROLE(), admin); // Admin can grant rep for test
        reputationManager.grantRole(reputationManager.REPUTATION_SLASHER_ROLE(), address(verifierManager)); // VerifierManager can slash

        // 4. Setup user states
        aztToken.mint(verifier1, INITIAL_MINT_AMOUNT);
        aztToken.mint(verifier2, INITIAL_MINT_AMOUNT);
        reputationManager.addReputation(verifier1, MIN_REPUTATION + 100);
        reputationManager.addReputation(verifier2, MIN_REPUTATION + 50);

        // Stop the admin prank before other users take actions
        vm.stopPrank();

        // 5. Create and activate a project
        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));

        vm.prank(projectOwner);
        projectRegistry.registerProject(projectId, "ipfs://project_metadata");

        // Admin must activate the project
        vm.prank(admin);
        projectRegistry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
    }

    function test_fullFlow_successfulVerification() public {
        // --- Step 1: Verifiers Register ---
        vm.startPrank(verifier1);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier2);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        assertTrue(verifierManager.isVerifier(verifier1));
        assertTrue(verifierManager.isVerifier(verifier2));

        // --- Step 2: Project Requests Verification ---
        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));
        bytes32 claimId = keccak256("Test Claim");
        string memory evidenceURI = "ipfs://test_evidence";

        vm.prank(projectOwner);
        bytes32 taskId = dMRVManager.requestVerification(projectId, claimId, evidenceURI, REP_WEIGHTED_MODULE_TYPE);
        assert(taskId != 0);

        // --- Step 3: Verifiers Vote ---
        vm.prank(verifier1);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.stopPrank();

        vm.prank(verifier2);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.stopPrank();

        // --- Step 4: Resolve the Task ---
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(admin); // Anyone can call resolve
        repWeightedVerifier.resolveTask(taskId);

        // --- Step 5: Verify Outcome ---
        uint256 expectedCreditAmount = 1; // The module sends 1 on success
        assertEq(
            creditContract.balanceOf(projectOwner, uint256(projectId)),
            expectedCreditAmount,
            "Impact credit was not minted"
        );
    }

    function test_fullFlow_failedVerification() public {
        // --- Step 1: Verifiers Register ---
        vm.startPrank(verifier1);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier2);
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        // --- Step 2: Project Requests Verification ---
        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));
        bytes32 claimId = keccak256("Test Claim For Rejection");
        string memory evidenceURI = "ipfs://test_evidence_rejection";

        vm.prank(projectOwner);
        bytes32 taskId = dMRVManager.requestVerification(projectId, claimId, evidenceURI, REP_WEIGHTED_MODULE_TYPE);

        // --- Step 3: Verifiers vote to cause a REJECTION ---
        // Verifier 1 (150 rep) votes REJECT
        vm.prank(verifier1);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject);
        vm.stopPrank();

        // Verifier 2 (100 rep) votes APPROVE
        vm.prank(verifier2);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.stopPrank();

        // --- Step 4: Resolve the Task ---
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.prank(admin);
        repWeightedVerifier.resolveTask(taskId);

        // --- Step 5: Verify Outcome ---
        uint256 expectedCreditAmount = 0;
        assertEq(
            creditContract.balanceOf(projectOwner, uint256(projectId)),
            expectedCreditAmount,
            "Impact credit should not have been minted on failure"
        );
    }

    function test_requestVerification_reverts_forInactiveProject() public {
        // --- Step 1: Create a new project but DO NOT activate it ---
        bytes32 inactiveProjectId = keccak256(abi.encodePacked(projectOwner, "My Inactive Project"));
        vm.prank(projectOwner);
        projectRegistry.registerProject(inactiveProjectId, "ipfs://inactive_project");

        // --- Step 2: Attempt to request verification ---
        bytes32 claimId = keccak256("Inactive Claim");

        vm.prank(projectOwner);
        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        dMRVManager.requestVerification(inactiveProjectId, claimId, "ipfs://evidence", REP_WEIGHTED_MODULE_TYPE);
    }

    function test_fullFlow_withSlashing() public {
        // --- Setup: Register both verifiers ---
        vm.startPrank(verifier1); // 150 rep
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        vm.startPrank(verifier2); // 100 rep
        aztToken.approve(address(verifierManager), MIN_STAKE_AMOUNT);
        verifierManager.register();
        vm.stopPrank();

        // --- Step 1: Admin slashes Verifier 1's reputation ---
        uint256 slashReputationAmount = 60;
        uint256 initialReputation = reputationManager.getReputation(verifier1);

        vm.prank(admin); // The admin was given SLASHER_ROLE in VerifierManager setup for this test
        verifierManager.slash(verifier1, 0, slashReputationAmount);

        uint256 finalReputation = reputationManager.getReputation(verifier1);
        assertEq(finalReputation, initialReputation - slashReputationAmount, "Verifier 1 reputation not slashed");
        // Verifier 1 now has 90 reputation, less than verifier 2's 100.

        // --- Step 2: Request a new verification ---
        bytes32 projectId = keccak256(abi.encodePacked(projectOwner, "My Test Project"));
        bytes32 claimId = keccak256("Post-Slashing Claim");

        vm.prank(projectOwner);
        bytes32 taskId =
            dMRVManager.requestVerification(projectId, claimId, "ipfs://evidence", REP_WEIGHTED_MODULE_TYPE);

        // --- Step 3: Verifiers vote, outcome is now different ---
        // Verifier 1 (now 90 rep) votes APPROVE
        vm.prank(verifier1);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Approve);
        vm.stopPrank();

        // Verifier 2 (100 rep) votes REJECT
        vm.prank(verifier2);
        repWeightedVerifier.submitVote(taskId, ReputationWeightedVerifier.Vote.Reject);
        vm.stopPrank();

        // --- Step 4: Resolve and check outcome ---
        // Before slashing, approve would have won (150 > 100). After, reject wins (100 > 90).
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.prank(admin);
        repWeightedVerifier.resolveTask(taskId);

        // --- Step 5: Verify Outcome ---
        uint256 expectedCreditAmount = 0;
        assertEq(
            creditContract.balanceOf(projectOwner, uint256(projectId)),
            expectedCreditAmount,
            "Impact credit should not have been minted after slashing changed outcome"
        );
    }
}
