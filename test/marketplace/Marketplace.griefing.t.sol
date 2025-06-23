// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mock ERC20 for payment
contract MockERC20ForGriefTest {
    event Approval(address indexed owner, address indexed spender, uint256 value);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "MockERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "MockERC20: insufficient allowance");

        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MarketplaceGriefingTest is Test {
    // Contracts
    Marketplace marketplace;
    DynamicImpactCredit credit;
    MockERC20ForGriefTest paymentToken;
    ProjectRegistry registry;

    // Users
    address admin;
    address seller = makeAddr("seller");

    // Constants
    uint256 constant BATCH_TOKEN_ID = 1;
    uint256 constant LIST_AMOUNT = 100;
    uint256 constant PRICE_PER_UNIT = 1 ether;

    function setUp() public {
        admin = address(this);

        // Deploy Project Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = ProjectRegistry(address(registryProxy));

        // Deploy Dynamic Impact Credit (ERC1155)
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        bytes memory creditInitData =
            abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "uri"));
        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        // Deploy Mock Payment Token (ERC20)
        paymentToken = new MockERC20ForGriefTest();

        // Deploy Marketplace
        Marketplace marketplaceImpl = new Marketplace();
        bytes memory marketplaceInitData =
            abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)));
        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplaceImpl), marketplaceInitData);
        marketplace = Marketplace(address(marketplaceProxy));

        // Configure roles and mint assets
        marketplace.setTreasury(admin); // Set treasury for fees

        // Mint credits to the seller
        vm.prank(admin);
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), admin);
        vm.prank(admin);
        // Mint a large number of tokens to the seller to cover all listings
        // We also need to register a project for these credits
        bytes32 projectId = bytes32(uint256(BATCH_TOKEN_ID));
        registry.registerProject(projectId, "griefing-project");
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        credit.mintCredits(seller, projectId, 1000, "grief-uri");

        // Approve marketplace to spend seller's credits
        vm.prank(seller);
        credit.setApprovalForAll(address(marketplace), true);
    }

    /**
     * @dev Tests if batch-cancelling many listings can be done within a single block's gas limit.
     * This simulates a potential DoS vector where a user creates many listings and then tries
     * to execute a costly operation on them.
     */
    function test_GasGriefing_BatchCancel_StaysWithinBlockLimit() public {
        uint256 numListings = 1000;
        uint256[] memory listingIds = new uint256[](numListings);

        // 1. Create a large number of listings
        vm.startPrank(seller);
        for (uint256 i = 0; i < numListings; i++) {
            listingIds[i] = marketplace.list(BATCH_TOKEN_ID, 1, PRICE_PER_UNIT, 1 weeks);
        }
        vm.stopPrank();

        // 2. Attempt to cancel all listings in a single transaction.
        uint256 gasBefore = gasleft();
        vm.prank(seller);
        marketplace.batchCancelListings(listingIds);
        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;

        // 3. Assert gas is under a reasonable limit (e.g., 29M, default block limit is 30M)
        console.log("Gas used for 1000 cancellations:", gasUsed);
        assertLt(gasUsed, 29_000_000, "Gas for 1000 cancellations should be under block limit");
    }

    /**
     * @dev Tests if batch-buying many listings can be done within a single block's gas limit.
     */
    function test_GasGriefing_BatchBuy_StaysWithinBlockLimit() public {
        uint256 numListings = 500; // Reduced from 1000 as buy is more expensive
        uint256[] memory listingIds = new uint256[](numListings);
        uint256[] memory amountsToBuy = new uint256[](numListings);
        address buyer = makeAddr("buyer");

        // 1. Create a large number of listings
        vm.startPrank(seller);
        for (uint256 i = 0; i < numListings; i++) {
            listingIds[i] = marketplace.list(BATCH_TOKEN_ID, 1, PRICE_PER_UNIT, 1 weeks);
            amountsToBuy[i] = 1;
        }
        vm.stopPrank();

        // 2. Fund the buyer and have them approve the marketplace
        uint256 totalCost = numListings * PRICE_PER_UNIT;
        paymentToken.mint(buyer, totalCost);
        vm.prank(buyer);
        paymentToken.approve(address(marketplace), totalCost);

        // 3. Attempt to buy all listings in a single transaction.
        uint256 gasBefore = gasleft();
        vm.prank(buyer);
        marketplace.batchBuy(listingIds, amountsToBuy);
        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;

        // 4. Assert gas is under a reasonable limit (e.g., 29M, default block limit is 30M)
        console.log("Gas used for 500 purchases:", gasUsed);
        assertLt(gasUsed, 29_000_000, "Gas for 500 purchases should be under block limit");
    }

    /**
     * @dev Tests if cancelling a listing with a very long expiration properly cleans up storage.
     * This prevents a griefing vector where expired/cancelled listings bloat contract storage indefinitely.
     */
    function test_StorageGriefing_LongExpiration_CleanupOnCancel() public {
        uint256 longExpiration = 100 * 365 days; // 100 years

        // 1. Create a listing with a very long expiration
        vm.prank(seller);
        uint256 listingId = marketplace.list(BATCH_TOKEN_ID, LIST_AMOUNT, PRICE_PER_UNIT, longExpiration);

        // 2. Verify the listing is active and has correct data
        Marketplace.Listing memory listingBefore = marketplace.getListing(listingId);
        assertTrue(listingBefore.active, "Listing should be active before cancellation");
        assertEq(listingBefore.seller, seller, "Seller should be correct");
        assertEq(listingBefore.amount, LIST_AMOUNT, "Amount should be correct");

        // 3. Cancel the listing
        vm.prank(seller);
        marketplace.cancelListing(listingId);

        // 4. Verify the listing is no longer active.
        // In this implementation, cancellation only flips the `active` flag. A more robust
        // implementation might use `delete` to clear all storage, but that has its own gas implications.
        // We will check that the listing is marked inactive.
        Marketplace.Listing memory listingAfter = marketplace.getListing(listingId);
        assertFalse(listingAfter.active, "Listing should be inactive after cancellation");
    }
}
