// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/AzemoraToken.sol";
import "../../src/governance/AzemoraGovernor.sol";
import "../../src/governance/AzemoraTimelockController.sol";
import "../../src/governance/Treasury.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/staking/StakingRewards.sol";
import "../../src/core/Bonding.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "forge-std/console.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import {MethodologyRegistry} from "../../src/core/MethodologyRegistry.sol";

// Mock is no longer needed
// contract MockERC20ForFlowTest { ... }

contract FullFlowTest is Test {
    // --- Contracts ---
    // Core Logic
    ProjectRegistry registry;
    DMRVManager dmrvManager;
    DynamicImpactCredit credit;
    Marketplace marketplace;
    MethodologyRegistry methodologyRegistry;
    // Governance
    AzemoraToken govToken;
    AzemoraGovernor governor;
    AzemoraTimelockController timelock;
    Treasury treasury;
    // Staking
    StakingRewards stakingRewards;
    // Bonding
    Bonding bonding;

    // --- Actors ---
    address admin = makeAddr("admin");
    address projectDeveloper = makeAddr("projectDeveloper");
    address verifier = makeAddr("verifier");
    address dmrvOracle = makeAddr("dmrvOracle");
    address buyer = makeAddr("buyer");
    address governanceProposer = makeAddr("governanceProposer");
    address feeRecipient = makeAddr("feeRecipient");
    address staker = makeAddr("staker");

    // --- Constants ---
    uint256 constant VOTING_DELAY = 1; // blocks
    uint256 constant VOTING_PERIOD = 5; // blocks
    uint256 constant MIN_DELAY = 1; // seconds
    uint256 constant QUORUM_PERCENTAGE = 4; // 4%

    function setUp() public {
        vm.startPrank(admin);

        // --- 1. DEPLOY GOVERNANCE & TREASURY ---
        AzemoraToken govTokenImpl = new AzemoraToken();
        govToken =
            AzemoraToken(address(new ERC1967Proxy(address(govTokenImpl), abi.encodeCall(AzemoraToken.initialize, ()))));

        AzemoraTimelockController timelockImpl = new AzemoraTimelockController();
        timelock = AzemoraTimelockController(
            payable(
                address(
                    new ERC1967Proxy(
                        address(timelockImpl),
                        abi.encodeCall(
                            AzemoraTimelockController.initialize, (MIN_DELAY, new address[](0), new address[](0), admin)
                        )
                    )
                )
            )
        );

        AzemoraGovernor governorImpl = new AzemoraGovernor();
        governor = AzemoraGovernor(
            payable(
                address(
                    new ERC1967Proxy(
                        address(governorImpl),
                        abi.encodeCall(
                            AzemoraGovernor.initialize,
                            (govToken, timelock, uint48(VOTING_DELAY), uint32(VOTING_PERIOD), 0, QUORUM_PERCENTAGE)
                        )
                    )
                )
            )
        );

        Treasury treasuryImpl = new Treasury();
        treasury = Treasury(
            payable(
                address(
                    new ERC1967Proxy(address(treasuryImpl), abi.encodeWithSelector(Treasury.initialize.selector, admin))
                )
            )
        );
        vm.deal(address(treasury), 10 ether); // Pre-fund treasury for other tests if needed

        // --- 2. DEPLOY CORE LOGIC ---
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );

        MethodologyRegistry methodologyRegistryImpl = new MethodologyRegistry();
        methodologyRegistry = MethodologyRegistry(
            address(
                new ERC1967Proxy(
                    address(methodologyRegistryImpl),
                    abi.encodeCall(MethodologyRegistry.initialize, (address(timelock)))
                )
            )
        );

        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(creditImpl),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://"))
                )
            )
        );

        DMRVManager dmrvManagerImpl = new DMRVManager();
        dmrvManager = DMRVManager(
            address(
                new ERC1967Proxy(
                    address(dmrvManagerImpl),
                    abi.encodeCall(
                        DMRVManager.initializeDMRVManager,
                        (address(registry), address(credit), address(methodologyRegistry))
                    )
                )
            )
        );

        // --- 3. DEPLOY MARKETPLACE ---
        Marketplace marketplaceImpl = new Marketplace();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(marketplaceImpl),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(govToken)))
                )
            )
        );

        // --- DEPLOY STAKING ---
        stakingRewards = new StakingRewards(address(govToken));

        // --- DEPLOY BONDING ---
        bonding = new Bonding(address(govToken), address(treasury));

        // --- 4. CONFIGURE ROLES & OWNERSHIP ---
        // Grant dMRVManager the right to mint credits
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dmrvManager));
        // Grant verifier role in the registry
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        // Grant admin role in dMRV Manager to the oracle for simplified testing
        dmrvManager.grantRole(dmrvManager.DEFAULT_ADMIN_ROLE(), dmrvOracle);
        // Set marketplace treasury TO THE STAKING CONTRACT
        marketplace.setTreasury(address(stakingRewards));
        marketplace.setFee(500); // 5% fee

        // Configure Governance
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 timelockAdminRole = timelock.DEFAULT_ADMIN_ROLE();

        timelock.grantRole(proposerRole, address(governor));
        timelock.grantRole(executorRole, address(0)); // Anyone can execute

        // Transfer contract ownership to the Timelock/DAO
        treasury.transferOwnership(address(timelock));
        bonding.transferOwnership(address(timelock));
        stakingRewards.transferOwnership(address(timelock));
        // Note: Other contracts with admin roles would also be transferred here in a real scenario
        // e.g., marketplace.grantRole(marketplace.DEFAULT_ADMIN_ROLE(), address(timelock));

        // Renounce initial admin control
        timelock.renounceRole(timelockAdminRole, admin);

        // --- FUND TREASURY ---
        govToken.transfer(address(treasury), 10_000_000e18);

        // --- 5. SETUP ACTOR STATE ---
        // Fund buyer with governance tokens (which are now also the payment token)
        govToken.transfer(buyer, 1_000_000 * 1e18);
        // Fund staker with payment tokens
        govToken.transfer(staker, 500_000 * 1e18);
        // Fund proposer with enough governance tokens to pass quorum (4% of 1B)
        govToken.transfer(governanceProposer, 40_000_000e18);

        vm.stopPrank(); // End the admin's multi-line prank

        vm.prank(governanceProposer); // Start a new single-line prank for the proposer
        govToken.delegate(governanceProposer);

        vm.roll(block.number + 1); // Let delegations register
    }

    function test_Full_End_To_End_Lifecycle() public {
        // --- STAGE 1: Project Creation & Verification ---
        bytes32 projectId = keccak256("Great Green Wall");
        vm.prank(projectDeveloper);
        registry.registerProject(projectId, "ipfs://great-green-wall");

        vm.prank(verifier);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        assertEq(
            uint256(registry.getProject(projectId).status),
            uint256(IProjectRegistry.ProjectStatus.Active),
            "Project should be active"
        );

        // --- STAGE 2: dMRV and Credit Minting ---
        uint256 creditsToMint = 500;
        string memory verificationURI = "ipfs://verification-report-1";

        // Oracle (with admin role) directly submits verification data,
        // bypassing the request/fulfill flow for this integration test.
        vm.prank(dmrvOracle);
        dmrvManager.adminSubmitVerification(projectId, creditsToMint, verificationURI, false);

        assertEq(
            credit.balanceOf(projectDeveloper, uint256(projectId)),
            creditsToMint,
            "Developer should have minted credits"
        );

        // --- STAGE 3: Marketplace Listing & Purchase ---
        uint256 listAmount = 100;
        uint256 pricePerUnit = 20 * 1e18; // 20 payment tokens per credit
        uint256 listingId;

        vm.startPrank(projectDeveloper);
        credit.setApprovalForAll(address(marketplace), true);
        listingId = marketplace.list(uint256(projectId), listAmount, pricePerUnit, 1 days);
        vm.stopPrank();

        assertEq(
            credit.balanceOf(address(marketplace), uint256(projectId)),
            listAmount,
            "Marketplace should hold listed credits"
        );

        uint256 buyAmount = 50;
        uint256 totalPrice = buyAmount * pricePerUnit;
        uint256 fee = (totalPrice * marketplace.feeBps()) / 10000;

        uint256 stakingContractInitialBalance = govToken.balanceOf(address(stakingRewards));

        vm.startPrank(buyer);
        govToken.approve(address(marketplace), totalPrice);
        marketplace.buy(listingId, buyAmount);
        vm.stopPrank();

        assertEq(credit.balanceOf(buyer, uint256(projectId)), buyAmount, "Buyer should receive purchased credits");
        assertEq(
            govToken.balanceOf(address(stakingRewards)),
            stakingContractInitialBalance + fee,
            "Staking contract should receive fees"
        );

        // --- STAGE 4: Staking & Governance Approves Reward Distribution ---

        // 4.1. A staker stakes their tokens, expecting a future reward
        vm.startPrank(staker);
        govToken.approve(address(stakingRewards), 500_000 * 1e18);
        stakingRewards.stake(500_000 * 1e18);
        vm.stopPrank();

        // 4.2. Governance must now approve the distribution of the collected fees.
        // To avoid precision loss in rewardRate calculation, we use a duration that divides the fee perfectly.
        // fee = 50e18, so we can use a duration of 50.
        uint256 rewardDuration = 50; // seconds

        // 4.2.1 Create Proposal
        address[] memory targets = new address[](1);
        targets[0] = address(stakingRewards);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(StakingRewards.notifyRewardAmount.selector, fee, rewardDuration);

        string memory description = "Distribute marketplace fees to stakers";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(governanceProposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // 4.2.2 Vote
        vm.roll(block.number + VOTING_DELAY + 1);
        assertEq(uint256(governor.state(proposalId)), 1, "Proposal should be Active"); // 1 = Active

        vm.prank(governanceProposer);
        governor.castVote(proposalId, 1); // 1 = For

        // 4.2.3 Queue & Execute
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint256(governor.state(proposalId)), 4, "Proposal should be Succeeded"); // 4 = Succeeded

        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(proposalId)), 7, "Proposal should be Executed"); // 7 = Executed

        // --- STAGE 5: Staker Claims Rewards ---
        vm.warp(block.timestamp + rewardDuration); // Advance time to the end of the reward period

        uint256 stakerBalanceBeforeClaim = govToken.balanceOf(staker);
        vm.prank(staker);
        stakingRewards.claimReward();
        uint256 stakerBalanceAfterClaim = govToken.balanceOf(staker);
        assertApproxEqAbs(stakerBalanceAfterClaim, stakerBalanceBeforeClaim + fee, 1, "Staker should earn full fee");
    }

    function test_Marketplace_Cancel_Flow() public {
        // --- STAGE 1: Project Creation & Minting (abbreviated) ---
        bytes32 projectId = keccak256("Cancellable Project");
        vm.prank(projectDeveloper);
        registry.registerProject(projectId, "ipfs://cancellable");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);

        // Directly submit verification as admin instead of request/fulfill
        vm.prank(dmrvOracle);
        dmrvManager.adminSubmitVerification(projectId, 100, "ipfs://verify-cancel", false);

        uint256 developerInitialBalance = credit.balanceOf(projectDeveloper, uint256(projectId));
        assertTrue(developerInitialBalance > 0, "Developer must have credits to list");

        // --- STAGE 2: List and then Cancel ---
        uint256 listAmount = 50;
        uint256 pricePerUnit = 10 * 1e18;
        uint256 listingId;

        vm.startPrank(projectDeveloper);
        credit.setApprovalForAll(address(marketplace), true);
        listingId = marketplace.list(uint256(projectId), listAmount, pricePerUnit, 1 days);

        // Verify tokens are now held by the marketplace
        assertEq(
            credit.balanceOf(address(marketplace), uint256(projectId)), listAmount, "Marketplace should custody tokens"
        );

        // Now, cancel the listing
        marketplace.cancelListing(listingId);
        vm.stopPrank();

        // --- STAGE 3: Final Verification ---
        // Verify the listing is no longer active
        Marketplace.Listing memory l = marketplace.getListing(listingId);
        assertFalse(l.active, "Listing should be inactive after cancellation");

        // Verify the tokens have been returned to the developer
        assertEq(
            credit.balanceOf(projectDeveloper, uint256(projectId)),
            developerInitialBalance,
            "Developer should have all their credits back after cancellation"
        );

        // Verify the marketplace no longer holds the tokens
        assertEq(
            credit.balanceOf(address(marketplace), uint256(projectId)),
            0,
            "Marketplace should have no credits after cancellation"
        );
    }

    function test_Bonding_Full_Lifecycle_With_Governance() public {
        // --- Define Parameters ---
        bytes32 projectId = keccak256("Unique Bonding Project");
        uint256 tokenId = uint256(projectId);
        uint256 pricePerCredit = 95e18; // 95 AZE per credit (5% discount from a hypothetical 100 AZE market price)
        uint256 vestingPeriod = 7 days;
        uint256 bondingContractFunding = 1_000_000e18; // 1M AZE to fund the contract

        // --- 1. GOVERNANCE: Propose to fund and activate the bonding program ---

        // We need two actions:
        // 1. Treasury sends AZE to the Bonding contract.
        // 2. Bonding contract sets the terms for the bond.
        address[] memory targets = new address[](2);
        targets[0] = address(treasury);
        targets[1] = address(bonding);

        uint256[] memory values = new uint256[](2); // No direct ETH transfers

        bytes[] memory calldatas = new bytes[](2);
        // Action 1: Treasury withdraws AZE to the Bonding contract
        calldatas[0] = abi.encodeWithSelector(
            treasury.withdrawERC20.selector, address(govToken), address(bonding), bondingContractFunding
        );
        // Action 2: Bonding contract sets the new bond term
        calldatas[1] = abi.encodeWithSelector(
            bonding.setBondTerm.selector, tokenId, address(credit), pricePerCredit, vestingPeriod, true
        );

        string memory description = "Activate and fund Impact Credit bonding program";
        bytes32 descriptionHash = keccak256(bytes(description));

        // Propose
        vm.prank(governanceProposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // --- 2. GOVERNANCE: Vote and Execute ---
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(governanceProposer);
        governor.castVote(proposalId, 1); // Vote FOR
        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        // --- 3. USER: Bond Assets ---
        // First, mint some credits to the project developer to bond with
        vm.startPrank(projectDeveloper);
        registry.registerProject(projectId, "ipfs://unique-bond-project");
        vm.stopPrank();
        vm.prank(verifier);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);

        // Oracle (with admin role) directly submits verification data
        vm.prank(dmrvOracle);
        dmrvManager.adminSubmitVerification(projectId, 100, "ipfs://verify-bond", false);

        uint256 amountToBond = 50;
        vm.startPrank(projectDeveloper);
        credit.setApprovalForAll(address(bonding), true);
        bonding.bond(tokenId, amountToBond);
        vm.stopPrank();

        // --- 4. USER: Claim Vested Tokens ---
        vm.warp(block.timestamp + vestingPeriod + 1);
        vm.prank(projectDeveloper);
        bonding.claim(0);
    }
}
