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
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Re-using the mock from marketplace tests
contract MockERC20ForFlowTest {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        // In the context of the treasury withdrawal, msg.sender will be the treasury contract
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract FullFlowTest is Test {
    // --- Contracts ---
    // Core Logic
    ProjectRegistry registry;
    DMRVManager dmrvManager;
    DynamicImpactCredit credit;
    Marketplace marketplace;
    // Governance
    AzemoraToken govToken;
    AzemoraGovernor governor;
    AzemoraTimelockController timelock;
    Treasury treasury;
    // Mocks
    MockERC20ForFlowTest paymentToken;

    // --- Actors ---
    address admin = makeAddr("admin");
    address projectDeveloper = makeAddr("projectDeveloper");
    address verifier = makeAddr("verifier");
    address dmrvOracle = makeAddr("dmrvOracle");
    address buyer = makeAddr("buyer");
    address governanceProposer = makeAddr("governanceProposer");
    address feeRecipient = makeAddr("feeRecipient");

    // --- Constants ---
    uint256 constant VOTING_DELAY = 1; // blocks
    uint256 constant VOTING_PERIOD = 5; // blocks
    uint256 constant MIN_DELAY = 1; // seconds

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
                            (govToken, timelock, uint48(VOTING_DELAY), uint32(VOTING_PERIOD), 0)
                        )
                    )
                )
            )
        );

        Treasury treasuryImpl = new Treasury();
        treasury = Treasury(
            payable(address(new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(Treasury.initialize, (admin)))))
        );
        vm.deal(address(treasury), 10 ether); // Pre-fund treasury for other tests if needed

        // --- 2. DEPLOY CORE LOGIC ---
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );

        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(creditImpl), abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://", address(registry)))
                )
            )
        );

        DMRVManager dmrvManagerImpl = new DMRVManager();
        dmrvManager = DMRVManager(
            address(
                new ERC1967Proxy(
                    address(dmrvManagerImpl),
                    abi.encodeCall(DMRVManager.initialize, (address(registry), address(credit)))
                )
            )
        );

        // --- 3. DEPLOY MARKETPLACE ---
        paymentToken = new MockERC20ForFlowTest();
        Marketplace marketplaceImpl = new Marketplace();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(marketplaceImpl),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)))
                )
            )
        );

        // --- 4. CONFIGURE ROLES & OWNERSHIP ---
        // Grant dMRVManager the right to mint credits
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dmrvManager));
        // Grant verifier role in the registry
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        // Grant oracle role in dMRV Manager
        dmrvManager.grantRole(dmrvManager.ORACLE_ROLE(), dmrvOracle);
        // Set marketplace treasury
        marketplace.setTreasury(address(treasury));
        marketplace.setFee(500); // 5% fee

        // Configure Governance
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 timelockAdminRole = timelock.DEFAULT_ADMIN_ROLE();

        timelock.grantRole(proposerRole, address(governor));
        timelock.grantRole(executorRole, address(0)); // Anyone can execute

        // Transfer contract ownership to the Timelock/DAO
        treasury.transferOwnership(address(timelock));
        // Note: Other contracts with admin roles would also be transferred here in a real scenario
        // e.g., marketplace.grantRole(marketplace.DEFAULT_ADMIN_ROLE(), address(timelock));

        // Renounce initial admin control
        timelock.renounceRole(timelockAdminRole, admin);

        // --- 5. SETUP ACTOR STATE ---
        // Fund buyer with payment tokens
        paymentToken.mint(buyer, 1_000_000 * 1e18);
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
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        assertEq(
            uint256(registry.getProject(projectId).status),
            uint256(ProjectRegistry.ProjectStatus.Active),
            "Project should be active"
        );

        // --- STAGE 2: dMRV and Credit Minting ---
        uint256 creditsToMint = 500;
        string memory verificationURI = "ipfs://verification-report-1";

        // 2.1 Project developer requests verification
        vm.prank(projectDeveloper);
        bytes32 requestId = dmrvManager.requestVerification(projectId);

        // 2.2 Oracle fulfills the verification request
        vm.prank(dmrvOracle);
        bytes memory verificationData = abi.encode(creditsToMint, false, bytes32(0), verificationURI);
        dmrvManager.fulfillVerification(requestId, verificationData);

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

        uint256 treasuryInitialBalance = paymentToken.balanceOf(address(treasury));

        vm.startPrank(buyer);
        paymentToken.approve(address(marketplace), totalPrice);
        marketplace.buy(listingId, buyAmount);
        vm.stopPrank();

        assertEq(credit.balanceOf(buyer, uint256(projectId)), buyAmount, "Buyer should receive purchased credits");
        assertEq(
            paymentToken.balanceOf(address(treasury)), treasuryInitialBalance + fee, "Treasury should receive fees"
        );

        // --- STAGE 4: Governance Withdraws Fees ---
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(address(treasury));
        uint256 recipientBalanceBefore = paymentToken.balanceOf(feeRecipient);

        // 4.1 Propose
        address[] memory targets = new address[](1);
        targets[0] = address(treasury); // The timelock will call the Treasury contract
        uint256[] memory values = new uint256[](1); // No ETH
        bytes[] memory calldatas = new bytes[](1);
        // The proposal tells the timelock to call 'withdrawERC20' on the treasury
        calldatas[0] = abi.encodeWithSelector(
            Treasury.withdrawERC20.selector, address(paymentToken), feeRecipient, treasuryBalanceBefore
        );

        string memory description = "Withdraw collected fees from Treasury";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(governanceProposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // 4.2 Vote
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(governanceProposer);
        governor.castVote(proposalId, uint8(1)); // Vote FOR

        // 4.3 Queue & Execute
        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        // --- STAGE 5: Final Verification ---
        assertEq(paymentToken.balanceOf(address(treasury)), 0, "Treasury should be empty after withdrawal");
        assertEq(
            paymentToken.balanceOf(feeRecipient),
            recipientBalanceBefore + treasuryBalanceBefore,
            "Fee Recipient should receive funds"
        );
    }
}
