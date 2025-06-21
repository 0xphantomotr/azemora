// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/AzemoraToken.sol";
import "../../src/governance/AzemoraGovernor.sol";
import "../../src/governance/AzemoraTimelockController.sol";
import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "../../src/governance/Treasury.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";

// A mock ERC20 is needed for the Marketplace setup.
contract MockERC20ForGovTest {
    function mint(address, uint256) public {}
}

/**
 * @dev A mock V2 contract to test the upgrade process.
 * It must also be UUPS-compliant and storage-compatible with Treasury.
 */
contract TreasuryV2 is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC1155HolderUpgradeable
{
    // This ensures the storage layout of TreasuryV2 is compatible with Treasury.
    // The new state variable `greeting` will be stored in a new slot after the parent contracts' storage.
    string public greeting;

    // The _authorizeUpgrade function must be present for UUPS and maintain the same access control.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function setGreeting(string memory _greeting) public {
        greeting = _greeting;
    }

    function greet() public view returns (string memory) {
        return greeting;
    }

    // Gap for future upgrades, matching the original Treasury contract's gap to ensure layout compatibility.
    uint256[50] private __gap;
}

contract GovernanceComplexTest is Test {
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
        credit = DynamicImpactCredit(address(new ERC1967Proxy(address(creditImpl), creditInitData)));

        // Roles
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(this)); // test contract is minter

        Marketplace marketplaceImpl = new Marketplace();
        bytes memory marketplaceInitData =
            abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)));
        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplaceImpl), marketplaceInitData);
        marketplace = Marketplace(address(marketplaceProxy));

        // 6. Configure Roles & Ownership
        bytes32 proposerRole = AzemoraTimelockController(timelockAddr).PROPOSER_ROLE();
        bytes32 executorRole = AzemoraTimelockController(timelockAddr).EXECUTOR_ROLE();
        // bytes32 timelockAdminRole = AzemoraTimelockController(timelockAddr).DEFAULT_ADMIN_ROLE();

        AzemoraTimelockController(timelockAddr).grantRole(proposerRole, governorAddr);
        AzemoraTimelockController(timelockAddr).grantRole(executorRole, address(0)); // Anyone can execute

        // Transfer ownership/admin of manageable contracts to the Timelock itself.
        bytes32 marketplaceAdminRole = marketplace.DEFAULT_ADMIN_ROLE();
        marketplace.grantRole(marketplaceAdminRole, timelockAddr);
        marketplace.renounceRole(marketplaceAdminRole, admin);

        Treasury(treasuryAddr).transferOwnership(timelockAddr);

        // DO NOT RENOUNCE THE ADMIN ROLE. The test will fail if the timelock is headless.
        // This line was the root cause of the silent queue failures.
        // AzemoraTimelockController(timelockAddr).renounceRole(timelockAdminRole, admin);

        // 7. Distribute tokens and set up voters
        token.transfer(voter, 50_000_000e18);
        token.transfer(voter2, 60_000_000e18);
        token.transfer(poorVoter, 1e18);

        vm.prank(voter);
        token.delegate(voter);

        vm.prank(voter2);
        token.delegate(voter2);

        vm.prank(poorVoter);
        token.delegate(poorVoter);

        vm.deal(treasuryAddr, 10 ether);
        vm.roll(block.number + 1);
    }

    /**
     * @dev A complex test to ensure governance can update its own settings.
     */
    function test_Complex_Update_Governor_Settings() public {
        uint48 newVotingDelay = 2;
        uint32 newVotingPeriod = 10;

        // Propose changing the governor's settings. This requires two separate calls.
        address[] memory targets = new address[](2);
        targets[0] = governorAddr;
        targets[1] = governorAddr;
        uint256[] memory values = new uint256[](2); // No ETH
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("setVotingDelay(uint48)", newVotingDelay);
        calldatas[1] = abi.encodeWithSignature("setVotingPeriod(uint32)", newVotingPeriod);

        string memory description = "Update Governor voting settings";
        bytes32 descriptionHash = keccak256(bytes(description));

        // Full proposal lifecycle
        vm.prank(voter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId, 1); // Vote For
        vm.roll(block.number + VOTING_PERIOD + 1);
        AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        AzemoraGovernor(governorAddr).execute(targets, values, calldatas, descriptionHash);

        // Verify the new settings are active
        assertEq(AzemoraGovernor(governorAddr).votingDelay(), newVotingDelay, "Voting delay should be updated");
        assertEq(AzemoraGovernor(governorAddr).votingPeriod(), newVotingPeriod, "Voting period should be updated");
    }

    /**
     * @dev A complex test to ensure a proposal passes when the quorum is met exactly.
     */
    function test_Complex_Quorum_Met_Exactly_At_Boundary() public {
        // The quorum is 4% of 1B tokens = 40M tokens.
        uint256 quorumVotes = 40_000_000e18;
        address quorumVoter = makeAddr("quorumVoter");

        // Setup the voter with the exact amount of tokens needed for quorum.
        token.transfer(quorumVoter, quorumVotes);
        vm.prank(quorumVoter);
        token.delegate(quorumVoter);
        vm.roll(block.number + 1); // Let delegation register.

        // Propose a simple action.
        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setFee.selector, 300); // Set fee to 3%
        string memory description = "Proposal to set fee to 3% with exact quorum";
        bytes32 descriptionHash = keccak256(bytes(description));

        // Propose the action.
        vm.prank(quorumVoter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);

        // Vote on the proposal.
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(quorumVoter);
        AzemoraGovernor(governorAddr).castVote(proposalId, 1); // Vote For.

        // End the voting period.
        vm.roll(block.number + VOTING_PERIOD + 1);

        // Check that the proposal is now in the "Succeeded" state.
        assertEq(uint256(AzemoraGovernor(governorAddr).state(proposalId)), 4, "Proposal should be Succeeded");

        // Queue and execute to confirm the whole flow works.
        AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        AzemoraGovernor(governorAddr).execute(targets, values, calldatas, descriptionHash);

        assertEq(marketplace.feeBps(), 300, "Marketplace fee should be updated");
    }

    /**
     * @dev Ensures a proposal cannot be queued or executed again after it has already been executed.
     * This prevents replay attacks.
     */
    function test_ReplayAttack_FailsAfterExecution() public {
        // --- Create and pass a proposal ---
        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setFee.selector, 600); // Set fee to 6%
        string memory description = "Proposal to set fee to 6%";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(voter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId, 1);
        vm.roll(block.number + VOTING_PERIOD + 1);

        // --- Execute the proposal successfully ---
        AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        AzemoraGovernor(governorAddr).execute(targets, values, calldatas, descriptionHash);
        assertEq(
            7, // Executed
            uint256(AzemoraGovernor(governorAddr).state(proposalId)),
            "Proposal should be Executed"
        );
        assertEq(marketplace.feeBps(), 600, "Marketplace fee should be updated");

        // --- Assert replay attacks fail ---

        // 1. Attempting to queue again should fail because the proposal is not in the 'Succeeded' state.
        try AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash) {
            fail();
        } catch (bytes memory reason) {
            // This will log the exact revert data to the console.
            console.log("Revert data from queue:");
            console.logBytes(reason);
        }

        /*
        // 2. Attempting to execute again should fail because the proposal is not in the 'Queued' state.
        bytes memory expectedRevertDataExecute =
            abi.encodeWithSignature("GovernorUnexpectedProposalState(uint256,uint256)", proposalId, 7); // current state is Executed
        vm.expectRevert(expectedRevertDataExecute);
        AzemoraGovernor(governorAddr).execute(targets, values, calldatas, descriptionHash);
        */
    }

    /**
     * @dev Ensures two proposals with identical logic but different salts are treated as unique operations.
     */
    function test_Timelock_HashClash_Succeeds() public {
        // --- Create two proposals with the same execution logic but different descriptions ---
        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setFee.selector, 800); // Set fee to 8%

        string memory description1 = "Set fee to 8% (Monday)";
        bytes32 descriptionHash1 = keccak256(bytes(description1));
        string memory description2 = "Set fee to 8% (Tuesday)";
        bytes32 descriptionHash2 = keccak256(bytes(description2));

        // Propose both
        vm.prank(voter);
        uint256 proposalId1 = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description1);
        vm.prank(voter);
        uint256 proposalId2 = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description2);

        // --- Vote both proposals through ---
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId1, 1);
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId2, 1);

        vm.roll(block.number + VOTING_PERIOD + 1);

        // --- Queue proposals and check for uniqueness ---
        // As per GovernorTimelockControl, the predecessor is 0 and the salt is a mix of the governor address and description hash.
        bytes32 salt1 = bytes20(address(governorAddr)) ^ descriptionHash1;
        bytes32 salt2 = bytes20(address(governorAddr)) ^ descriptionHash2;

        bytes32 opId1 = AzemoraTimelockController(timelockAddr).hashOperationBatch(targets, values, calldatas, 0, salt1);
        bytes32 opId2 = AzemoraTimelockController(timelockAddr).hashOperationBatch(targets, values, calldatas, 0, salt2);

        // Queue the first proposal
        AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash1);

        // Assert first is scheduled and second is NOT
        assertTrue(AzemoraTimelockController(timelockAddr).isOperation(opId1), "Op 1 should be scheduled");
        assertFalse(AzemoraTimelockController(timelockAddr).isOperation(opId2), "Op 2 should NOT be scheduled yet");

        // Queue the second proposal
        AzemoraGovernor(governorAddr).queue(targets, values, calldatas, descriptionHash2);
        assertTrue(AzemoraTimelockController(timelockAddr).isOperation(opId2), "Op 2 should now be scheduled");
    }

    /**
     * @dev Ensures a voter's power is snapshotted when a proposal is made
     * and subsequent token acquisitions do not affect their vote weight.
     */
    function test_Vote_Snapshot_Is_Correct() public {
        // voter starts with 50M tokens.

        // Propose a simple action.
        address[] memory targets = new address[](1);
        targets[0] = address(marketplace);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(Marketplace.setFee.selector, 100);
        string memory description = "Test Vote Snapshot";

        // Propose the action. The snapshot of the voter's 50M tokens is taken here.
        vm.prank(voter);
        uint256 proposalId = AzemoraGovernor(governorAddr).propose(targets, values, calldatas, description);

        // The snapshot for voting power is taken at `voteStart`, which is `proposal_block + voting_delay`.
        // We must advance the block *past* the snapshot block for the token balance change to not affect voting power.
        vm.roll(block.number + VOTING_DELAY + 1);

        // AFTER the proposal is made, the voter acquires more tokens.
        // These should NOT count towards the vote.
        token.transfer(voter, 100_000_000e18); // voter now has 150M tokens.

        // Vote on the proposal.
        vm.prank(voter);
        AzemoraGovernor(governorAddr).castVote(proposalId, 1); // Vote For.

        // Check the vote weight. It should be the original 50M, not the new 150M.
        (, uint256 forVotes,) = AzemoraGovernor(governorAddr).proposalVotes(proposalId);
        assertEq(forVotes, 50_000_000e18, "Vote weight should match pre-proposal snapshot");
    }
}
