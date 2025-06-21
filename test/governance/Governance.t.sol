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
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// A mock ERC20 is needed for the Marketplace setup.
// We can define it here to keep the test self-contained.
contract MockERC20ForGovTest {
    function mint(address, uint256) public {}
}

contract GovernanceTest is Test {
    // Use addresses instead of contract references to avoid conversion issues
    AzemoraToken token;
    address payable public timelockAddr;
    address payable public governorAddr;
    address payable public treasuryAddr;
    Marketplace marketplace;
    DynamicImpactCredit credit;
    MockERC20ForGovTest paymentToken;

    // Users
    address admin;
    address voter = makeAddr("voter");
    address voter2 = makeAddr("voter2");
    address poorVoter = makeAddr("poorVoter");
    address recipient = makeAddr("recipient");

    // Governance settings
    uint256 constant VOTING_DELAY = 1; // blocks
    uint256 constant VOTING_PERIOD = 5; // blocks
    uint256 constant MIN_DELAY = 1; // seconds
    uint256 constant PROPOSAL_THRESHOLD = 1000e18;
    uint256 constant QUORUM_PERCENTAGE = 4; // 4%

    function setUp() public {
        admin = address(this);

        // 1. Deploy Governance Token
        AzemoraToken tokenImpl = new AzemoraToken();
        bytes memory tokenInitData = abi.encodeCall(AzemoraToken.initialize, ());
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = AzemoraToken(address(tokenProxy));

        // 2. Deploy Timelock
        AzemoraTimelockController timelockImpl = new AzemoraTimelockController();
        bytes memory timelockInitData =
            abi.encodeCall(AzemoraTimelockController.initialize, (MIN_DELAY, new address[](0), new address[](0), admin));
        ERC1967Proxy timelockProxy = new ERC1967Proxy(address(timelockImpl), timelockInitData);
        timelockAddr = payable(address(timelockProxy));

        // 3. Deploy Governor
        AzemoraGovernor governorImpl = new AzemoraGovernor();
        // Use temporary direct casting for initialization only
        bytes memory governorInitData = abi.encodeCall(
            AzemoraGovernor.initialize,
            (
                token,
                AzemoraTimelockController(timelockAddr),
                uint48(VOTING_DELAY),
                uint32(VOTING_PERIOD),
                PROPOSAL_THRESHOLD,
                QUORUM_PERCENTAGE
            )
        );
        ERC1967Proxy governorProxy = new ERC1967Proxy(address(governorImpl), governorInitData);
        governorAddr = payable(address(governorProxy));

        // 4. Deploy Treasury
        Treasury treasuryImpl = new Treasury();
        bytes memory treasuryInitData = abi.encodeCall(Treasury.initialize, (admin));
        ERC1967Proxy treasuryProxy = new ERC1967Proxy(address(treasuryImpl), treasuryInitData);
        treasuryAddr = payable(address(treasuryProxy));

        // 5. Deploy Marketplace and its dependencies
        paymentToken = new MockERC20ForGovTest();

        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        ProjectRegistry registry = ProjectRegistry(address(registryProxy));

        DynamicImpactCredit creditImpl = new DynamicImpactCredit(address(registry));
        bytes memory creditInitData = abi.encodeCall(DynamicImpactCredit.initialize, ("uri"));
        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        Marketplace marketplaceImpl = new Marketplace();
        bytes memory marketplaceInitData =
            abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)));
        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplaceImpl), marketplaceInitData);
        marketplace = Marketplace(address(marketplaceProxy));

        // 6. Configure Roles & Ownership using direct calls with casts
        // This is safe because we're only temporarily casting for function calls
        bytes32 proposerRole = AzemoraTimelockController(timelockAddr).PROPOSER_ROLE();
        bytes32 executorRole = AzemoraTimelockController(timelockAddr).EXECUTOR_ROLE();
        bytes32 timelockAdminRole = AzemoraTimelockController(timelockAddr).DEFAULT_ADMIN_ROLE();

        AzemoraTimelockController(timelockAddr).grantRole(proposerRole, governorAddr);
        AzemoraTimelockController(timelockAddr).grantRole(executorRole, address(0)); // Anyone can execute
        AzemoraTimelockController(timelockAddr).renounceRole(timelockAdminRole, admin);

        // Transfer ownership of manageable contracts to the Timelock
        bytes32 marketplaceAdminRole = marketplace.DEFAULT_ADMIN_ROLE();
        marketplace.grantRole(marketplaceAdminRole, timelockAddr);
        marketplace.renounceRole(marketplaceAdminRole, admin);

        // Transfer Treasury ownership to timelock
        Treasury(treasuryAddr).transferOwnership(timelockAddr);

        // 7. Distribute tokens and set up voters
        // Voter needs >4% of total supply (1B) to meet quorum. 50M = 5%.
        token.transfer(voter, 50_000_000e18); // Give voter 50M tokens (5%)
        token.transfer(voter2, 60_000_000e18); // Give voter2 60M tokens (6%) to have more power
        token.transfer(poorVoter, 1e18); // Give poorVoter 1 token (below proposal threshold)

        vm.prank(voter);
        token.delegate(voter); // Voter delegates voting power to themselves

        vm.prank(voter2);
        token.delegate(voter2);

        vm.prank(poorVoter);
        token.delegate(poorVoter);

        // Fund the treasury for the withdrawal test
        vm.deal(treasuryAddr, 10 ether);

        // Advance a block to ensure delegations are registered before any proposal is made
        vm.roll(block.number + 1);
    }

    function test_Governance_Full_Flow() public {
        // --- 1. Propose ---
        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1); // No ETH being sent
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setTreasury.selector, treasuryAddr);
        string memory description = "Set marketplace fee recipient to Treasury";
        bytes32 descriptionHash = keccak256(bytes(description));

        // Propose the action - use temporary casting
        vm.prank(voter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);

        // --- 2. Vote ---
        vm.roll(block.number + VOTING_DELAY + 1); // Wait for voting delay

        // Vote in favor - use temporary casting
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId, uint8(1)); // 1 = For

        // --- 3. Queue ---
        vm.roll(block.number + VOTING_PERIOD + 1); // Wait for voting period to end

        // Queue the proposal - use temporary casting
        AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash);

        // --- 4. Execute ---
        vm.warp(block.timestamp + MIN_DELAY + 1); // Wait for the timelock min delay

        // Execute the proposal - use temporary casting
        AzemoraGovernor(governorAddr).execute(targets, values, calldatas, descriptionHash);

        // --- 5. Verify ---
        assertEq(marketplace.treasury(), treasuryAddr, "Fee recipient should be the Treasury");
    }

    function test_Fail_When_Quorum_Not_Met() public {
        // --- 1. Propose ---
        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1); // No ETH being sent
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setTreasury.selector, treasuryAddr);
        string memory description = "Set marketplace fee recipient to Treasury";

        // Propose the action with a valid proposer
        vm.prank(voter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);

        // --- 2. Vote ---
        vm.roll(block.number + VOTING_DELAY + 1); // Wait for voting delay

        // Vote with a user who doesn't have enough tokens to meet quorum
        vm.prank(poorVoter);
        AzemoraGovernor(governorAddr).castVote(proposalId, uint8(1)); // 1 = For

        // --- 3. Check State ---
        vm.roll(block.number + VOTING_PERIOD + 1); // Wait for voting period to end

        // Proposal should be defeated because quorum was not met
        assertEq(uint256(AzemoraGovernor(governorAddr).state(proposalId)), 3); // 3 = Defeated
    }

    function test_Fail_When_Voted_Down() public {
        // --- 1. Propose ---
        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1); // No ETH being sent
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setTreasury.selector, treasuryAddr);
        string memory description = "Set marketplace fee recipient to Treasury";

        // voter proposes
        vm.prank(voter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);

        // --- 2. Vote ---
        vm.roll(block.number + VOTING_DELAY + 1); // Wait for voting delay

        // voter votes FOR
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId, uint8(1)); // 1 = For

        // voter2 has more tokens and votes AGAINST
        vm.prank(voter2);
        AzemoraGovernor(governorAddr).castVote(proposalId, uint8(0)); // 0 = Against

        // --- 3. Check State ---
        vm.roll(block.number + VOTING_PERIOD + 1); // Wait for voting period to end

        // Proposal should be defeated because against votes > for votes
        assertEq(uint256(AzemoraGovernor(governorAddr).state(proposalId)), 3); // 3 = Defeated
    }

    function test_Propose_And_Withdraw_From_Treasury() public {
        uint256 startingBalance = recipient.balance;
        uint256 treasuryBalance = address(treasuryAddr).balance;
        uint256 withdrawAmount = 1 ether;

        // --- 1. Propose ---
        address[] memory targets = new address[](1);
        targets[0] = treasuryAddr;
        uint256[] memory values = new uint256[](1); // No ETH being sent with the proposal itself
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Treasury.withdrawETH.selector, recipient, withdrawAmount);
        string memory description = "Proposal to withdraw 1 ETH from Treasury";
        bytes32 descriptionHash = keccak256(bytes(description));

        // Propose the action
        vm.prank(voter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);

        // --- 2. Vote ---
        vm.roll(block.number + VOTING_DELAY + 1); // Wait for voting delay

        // Vote in favor
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId, uint8(1)); // 1 = For

        // --- 3. Queue ---
        vm.roll(block.number + VOTING_PERIOD + 1); // Wait for voting period to end

        // Queue the proposal
        AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash);

        // --- 4. Execute ---
        vm.warp(block.timestamp + MIN_DELAY + 1); // Wait for the timelock min delay

        // Execute the proposal
        AzemoraGovernor(governorAddr).execute(targets, values, calldatas, descriptionHash);

        // --- 5. Verify ---
        assertEq(recipient.balance, startingBalance + withdrawAmount, "Recipient should have received ETH");
        assertEq(
            address(treasuryAddr).balance, treasuryBalance - withdrawAmount, "Treasury balance should have decreased"
        );
    }

    function test_Fail_If_Proposer_Below_Threshold() public {
        vm.prank(poorVoter);

        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setTreasury.selector, treasuryAddr);
        string memory description = "This proposal should fail";

        vm.expectRevert(
            abi.encodeWithSignature(
                "GovernorInsufficientProposerVotes(address,uint256,uint256)", poorVoter, 1e18, PROPOSAL_THRESHOLD
            )
        );
        AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);
    }

    function test_Proposal_Cancellation_Permissions() public {
        // --- Setup ---
        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setTreasury.selector, treasuryAddr);

        // --- Scenario 1: Proposer CAN cancel ---
        string memory description1 = "Proposal 1";
        bytes32 descriptionHash1 = keccak256(bytes(description1));
        vm.prank(voter);
        uint256 proposalId1 = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description1);

        vm.prank(voter); // The proposer themself cancels
        AzemoraGovernor(governorAddr).cancel(targets, values, calldatas, descriptionHash1);
        assertEq(uint256(AzemoraGovernor(governorAddr).state(proposalId1)), 2, "State should be Canceled by proposer");

        // --- Scenario 2: Non-proposer CANNOT cancel ---
        string memory description2 = "Proposal 2";
        bytes32 descriptionHash2 = keccak256(bytes(description2));
        vm.prank(voter); // voter makes a new proposal
        uint256 proposalId2 = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description2);

        vm.prank(voter2); // Non-proposer (voter2) attempts to cancel
        vm.expectRevert(abi.encodeWithSignature("GovernorUnableToCancel(uint256,address)", proposalId2, voter2));
        AzemoraGovernor(governorAddr).cancel(targets, values, calldatas, descriptionHash2);

        // Verify state is unchanged after failed cancellation attempt
        assertEq(uint256(AzemoraGovernor(governorAddr).state(proposalId2)), 0, "State should still be Pending");
    }

    function test_Execution_Fails_If_Target_Call_Reverts() public {
        uint256 treasuryBalance = address(treasuryAddr).balance; // 10 ether
        uint256 withdrawAmount = treasuryBalance + 1 ether; // Attempt to withdraw more than available

        // --- 1. Propose ---
        address[] memory targets = new address[](1);
        targets[0] = treasuryAddr;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Treasury.withdrawETH.selector, recipient, withdrawAmount);
        string memory description = "Proposal to withdraw more ETH than available";
        bytes32 descriptionHash = keccak256(bytes(description));

        // Propose, vote, and queue successfully
        vm.prank(voter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId, uint8(1));
        vm.roll(block.number + VOTING_PERIOD + 1);
        AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash);

        // --- 2. Execute ---
        vm.warp(block.timestamp + MIN_DELAY + 1);

        // Expect execution to fail because the treasury withdrawal will revert
        vm.expectRevert("Insufficient ETH balance");
        AzemoraGovernor(governorAddr).execute(targets, values, calldatas, descriptionHash);
    }
}
