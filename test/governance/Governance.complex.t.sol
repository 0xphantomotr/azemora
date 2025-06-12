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
contract MockERC20ForGovTest {
    function mint(address, uint256) public {}
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
                PROPOSAL_THRESHOLD
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

        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        bytes memory creditInitData = abi.encodeCall(DynamicImpactCredit.initialize, ("uri", address(registry)));
        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        Marketplace marketplaceImpl = new Marketplace();
        bytes memory marketplaceInitData =
            abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)));
        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplaceImpl), marketplaceInitData);
        marketplace = Marketplace(address(marketplaceProxy));

        // 6. Configure Roles & Ownership
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

        Treasury(treasuryAddr).transferOwnership(timelockAddr);

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
}
