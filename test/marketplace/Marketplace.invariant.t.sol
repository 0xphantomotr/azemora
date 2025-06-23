// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./Marketplace.t.sol"; // Re-use mocks
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/marketplace/Marketplace.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Handler contract to perform random actions on the Marketplace
contract MarketplaceHandler is Test {
    ProjectRegistry public registry;
    DynamicImpactCredit public credit;
    Marketplace public marketplace;
    MockERC20 public paymentToken;

    // --- State tracking for invariants ---
    // We don't need to track credit balances here, as the credit contract has its own invariants.
    // We will track payment token balances to ensure conservation.
    mapping(address => uint256) public userPaymentTokenBalances;

    // --- Actors ---
    address public admin;
    address public verifier;
    address public dmrvManager;
    address public treasury;
    address[] public users; // Sellers and buyers

    // --- Available assets ---
    bytes32[] public projectIds;
    mapping(bytes32 => bool) public projectIdExists;
    mapping(bytes32 => uint256) public totalCreditSupply;

    function getUsersLength() public view returns (uint256) {
        return users.length;
    }

    function getProjectIdsLength() public view returns (uint256) {
        return projectIds.length;
    }

    constructor(
        ProjectRegistry _registry,
        DynamicImpactCredit _credit,
        Marketplace _marketplace,
        MockERC20 _paymentToken,
        address _admin,
        address _verifier,
        address _dmrvManager,
        address _treasury
    ) {
        registry = _registry;
        credit = _credit;
        marketplace = _marketplace;
        paymentToken = _paymentToken;
        admin = _admin;
        verifier = _verifier;
        dmrvManager = _dmrvManager;
        treasury = _treasury;

        // Create test users
        for (uint256 i = 0; i < 4; i++) {
            users.push(address(uint160(uint256(keccak256(abi.encodePacked("user", i))))));
        }

        // Fund users and track initial balances
        for (uint256 i = 0; i < users.length; i++) {
            uint256 initialBalance = 1_000_000 * 1e6;
            paymentToken.mint(users[i], initialBalance);
            userPaymentTokenBalances[users[i]] = initialBalance;
        }
        // Fee recipient starts with 0
        userPaymentTokenBalances[treasury] = 0;

        // Target the handler so that fuzz inputs are sent to its public functions
        targetContract(address(this));
    }

    /* --- ACTIONS --- */

    // Action: A random user lists a random amount of a random credit
    function list(uint256 seed, uint256 listAmount, uint256 price) public {
        // 1. Get a seller
        address seller = users[seed % users.length];

        // 2. Ensure seller has something to sell. If not, mint them some credits.
        bytes32 projectId = keccak256(abi.encodePacked("project", seed % 5)); // Limit to 5 projects
        if (!projectIdExists[projectId]) {
            // Create the project and mint initial credits
            uint256 mintAmount = 1_000_000;
            vm.prank(seller);
            registry.registerProject(projectId, "ipfs://fuzz.json");
            vm.prank(verifier);
            registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
            vm.prank(dmrvManager);
            credit.mintCredits(seller, projectId, mintAmount, "uri");

            projectIds.push(projectId);
            projectIdExists[projectId] = true;
            totalCreditSupply[projectId] = mintAmount;
        }

        // 3. Bound inputs
        uint256 sellerBalance = credit.balanceOf(seller, uint256(projectId));
        if (sellerBalance == 0) return; // Nothing to list
        listAmount = bound(listAmount, 1, sellerBalance);
        price = bound(price, 1, 1_000_000 * 1e6);

        // 4. Execute: List the item
        vm.startPrank(seller);
        credit.setApprovalForAll(address(marketplace), true);
        marketplace.list(uint256(projectId), listAmount, price, 1 days);
        vm.stopPrank();
    }

    // Action: A random user buys from a random active listing
    function buy(uint256 seed, uint256 listingId, uint256 buyAmount) public {
        uint256 activeListingCount = marketplace.activeListingCount();
        if (activeListingCount == 0) return;

        listingId = bound(listingId, 0, marketplace.listingIdCounter() - 1);
        Marketplace.Listing memory l = marketplace.getListing(listingId);

        if (!l.active) return; // Can't buy from inactive listing

        // 1. Get a buyer (cannot be the seller)
        address buyer;
        uint256 i = 0;
        do {
            buyer = users[(seed + i) % users.length];
            i++;
        } while (buyer == l.seller);

        // 2. Bound inputs
        buyAmount = bound(buyAmount, 1, l.amount);

        // 3. Ensure buyer can afford it and update tracked balances
        uint256 totalPrice = buyAmount * l.pricePerUnit;
        if (paymentToken.balanceOf(buyer) < totalPrice) return;

        uint256 fee = (totalPrice * marketplace.feeBps()) / 10000;
        uint256 sellerProceeds = totalPrice - fee;

        userPaymentTokenBalances[buyer] -= totalPrice;
        userPaymentTokenBalances[l.seller] += sellerProceeds;
        userPaymentTokenBalances[treasury] += fee;

        // 4. Execute: Buyer approves and buys
        vm.startPrank(buyer);
        paymentToken.approve(address(marketplace), totalPrice);
        marketplace.buy(listingId, buyAmount);
        vm.stopPrank();
    }

    // Action: A random seller cancels their listing
    function cancel(uint256 listingId) public {
        uint256 listingCounter = marketplace.listingIdCounter();
        if (listingCounter == 0) return;
        listingId = bound(listingId, 0, listingCounter - 1);

        Marketplace.Listing memory l = marketplace.getListing(listingId);
        if (!l.active) return;

        vm.prank(l.seller);
        try marketplace.cancelListing(listingId) {
            // success is okay
        } catch {
            // revert is okay
        }
    }
}

// The Invariant Test Contract
contract MarketplaceInvariantTest is StdInvariant, Test {
    MarketplaceHandler handler;
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    Marketplace marketplace;
    MockERC20 paymentToken;

    function setUp() public {
        // --- Deploy Infrastructure ---
        address admin = address(0xA11CE);
        address verifier = address(0xC1E4);
        address dmrvManager = address(0xB01D);
        address treasury = address(0xFE35);

        vm.startPrank(admin);
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(creditImpl),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "uri"))
                )
            )
        );
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), dmrvManager);

        paymentToken = new MockERC20("USD Coin", "USDC", 6);
        Marketplace marketplaceImpl = new Marketplace();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(marketplaceImpl),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)))
                )
            )
        );
        marketplace.setTreasury(treasury);
        marketplace.setFee(250); // 2.5% fee
        vm.stopPrank();

        // --- Set up Handler ---
        handler =
            new MarketplaceHandler(registry, credit, marketplace, paymentToken, admin, verifier, dmrvManager, treasury);

        // Target the handler so that fuzz inputs are sent to its public functions
        targetContract(address(handler));
    }

    // INVARIANT 1: Payment tokens are conserved.
    // The total amount of payment tokens across all users and the fee recipient
    // should always equal the sum of their initial balances.
    function invariant_paymentTokenIsConserved() public view {
        uint256 totalTrackedBalance = 0;
        uint256 totalActualBalance = 0;

        uint256 usersLength = handler.getUsersLength();
        for (uint256 i = 0; i < usersLength; i++) {
            address user = handler.users(i);
            totalTrackedBalance += handler.userPaymentTokenBalances(user);
            totalActualBalance += handler.paymentToken().balanceOf(user);
        }

        address treasury_ = handler.treasury();
        totalTrackedBalance += handler.userPaymentTokenBalances(treasury_);
        totalActualBalance += handler.paymentToken().balanceOf(treasury_);

        assertEq(totalTrackedBalance, totalActualBalance, "Payment token conservation broken");
    }

    // INVARIANT 2: Marketplace holds no payment tokens.
    // The marketplace contract should only be a conduit for payment tokens, not hold them.
    function invariant_marketplaceHoldsNoPaymentTokens() public view {
        assertEq(
            handler.paymentToken().balanceOf(address(handler.marketplace())), 0, "Marketplace holds payment tokens"
        );
    }

    // INVARIANT 3: Credit tokens are conserved.
    // The total number of tokens for each project ID should remain constant across
    // all users and the marketplace itself.
    function invariant_creditTokenIsConserved() public view {
        uint256 projectsLength = handler.getProjectIdsLength();
        for (uint256 i = 0; i < projectsLength; i++) {
            bytes32 projectId = handler.projectIds(i);
            uint256 tokenId = uint256(projectId);

            // Get the initial total supply that was minted for this project
            uint256 initialTotalSupply = handler.totalCreditSupply(projectId);

            // Calculate the current total supply held by all actors
            uint256 currentTotalSupply = 0;

            // Add balances of all users
            uint256 usersLength = handler.getUsersLength();
            for (uint256 j = 0; j < usersLength; j++) {
                address user = handler.users(j);
                currentTotalSupply += handler.credit().balanceOf(user, tokenId);
            }

            // Add balance held by the marketplace contract
            currentTotalSupply += handler.credit().balanceOf(address(handler.marketplace()), tokenId);

            // The current total supply should always equal the initial total supply
            assertEq(currentTotalSupply, initialTotalSupply, "Credit token conservation broken");
        }
    }
}
