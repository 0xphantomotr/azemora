// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./Marketplace.t.sol"; // Import the mock ERC20 from the other test file
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/marketplace/Marketplace.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";

contract MarketplaceComplexTest is Test {
    // Core contracts
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    Marketplace marketplace;
    MockERC20 paymentToken;

    // Users
    address admin = address(0xA11CE);
    address verifier = address(0xC1E4);
    address dmrvManager = address(0xB01D);
    address treasury = address(0xFE35);
    address seller1 = address(0x5E11E1);
    address seller2 = address(0x5E11E2);
    address buyer1 = address(0xB4BE1);
    address buyer2 = address(0xB4BE2);

    // Project and Token IDs
    bytes32 projectId1 = keccak256("Project Alpha");
    bytes32 projectId2 = keccak256("Project Beta");
    uint256 tokenId1;
    uint256 tokenId2;

    function setUp() public {
        tokenId1 = uint256(projectId1);
        tokenId2 = uint256(projectId2);

        // --- Deploy Infrastructure ---
        paymentToken = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(address(this));
        paymentToken.mint(buyer1, 1_000_000 * 1e6); // 1M USDC
        vm.prank(address(this));
        paymentToken.mint(buyer2, 1_000_000 * 1e6); // 1M USDC

        vm.startPrank(admin);

        // Deploy Registry, Credit, and Marketplace contracts
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(new ProjectRegistry()), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(creditImpl),
                    abi.encodeCall(
                        DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://meta.json")
                    )
                )
            )
        );
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), dmrvManager);

        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(new Marketplace()),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)))
                )
            )
        );
        marketplace.setTreasury(treasury);
        marketplace.setProtocolFeeBps(250); // Initial 2.5% fee

        vm.stopPrank();

        // --- Prepare Projects and Credits ---
        // Project 1 for seller1
        vm.prank(seller1);
        registry.registerProject(projectId1, "ipfs://alpha.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId1, IProjectRegistry.ProjectStatus.Active);
        vm.prank(dmrvManager);
        credit.mintCredits(seller1, projectId1, 500, "ipfs://c-alpha.json");

        // Project 2 for seller2
        vm.prank(seller2);
        registry.registerProject(projectId2, "ipfs://beta.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId2, IProjectRegistry.ProjectStatus.Active);
        vm.prank(dmrvManager);
        credit.mintCredits(seller2, projectId2, 1000, "ipfs://c-beta.json");
    }

    function testComplex_MultiUserFlow() public {
        // STEP 1: Both sellers approve the marketplace and list their tokens
        vm.startPrank(seller1);
        credit.setApprovalForAll(address(marketplace), true);
        uint256 listingId1 = marketplace.list(tokenId1, 200, 10 * 1e6, 1 days); // 200 tokens at 10 USDC
        vm.stopPrank();

        vm.startPrank(seller2);
        credit.setApprovalForAll(address(marketplace), true);
        uint256 listingId2 = marketplace.list(tokenId2, 500, 15 * 1e6, 1 days); // 500 tokens at 15 USDC
        vm.stopPrank();

        assertEq(credit.balanceOf(address(marketplace), tokenId1), 200);
        assertEq(credit.balanceOf(address(marketplace), tokenId2), 500);

        // STEP 2: Buyer1 makes a partial purchase from seller1
        uint256 buyAmount1 = 50;
        uint256 totalPrice1 = buyAmount1 * 10 * 1e6;

        vm.startPrank(buyer1);
        paymentToken.approve(address(marketplace), totalPrice1);
        marketplace.buy(listingId1, buyAmount1);
        vm.stopPrank();

        Marketplace.Listing memory listing1 = marketplace.getListing(listingId1);
        assertEq(listing1.amount, 150); // 200 - 50
        assertEq(credit.balanceOf(buyer1, tokenId1), buyAmount1);
        assertEq(credit.balanceOf(address(marketplace), tokenId1), 150);

        // STEP 3: Seller1 decides to update the price of the remaining items
        vm.prank(seller1);
        marketplace.updateListingPrice(listingId1, 12 * 1e6); // New price is 12 USDC

        listing1 = marketplace.getListing(listingId1);
        assertEq(listing1.pricePerUnit, 12 * 1e6);

        // STEP 4: Buyer2 buys all remaining items from listing 1 at the new price
        uint256 buyAmount2 = 150;
        uint256 totalPrice2 = buyAmount2 * 12 * 1e6; // Use the new price
        uint256 fee2 = (totalPrice2 * 250) / 10000;
        uint256 proceeds2 = totalPrice2 - fee2;
        uint256 seller1InitialPayment = paymentToken.balanceOf(seller1);

        vm.startPrank(buyer2);
        paymentToken.approve(address(marketplace), totalPrice2);
        marketplace.buy(listingId1, buyAmount2);
        vm.stopPrank();

        listing1 = marketplace.getListing(listingId1);
        assertFalse(listing1.active);
        assertEq(credit.balanceOf(buyer2, tokenId1), buyAmount2);
        assertEq(credit.balanceOf(address(marketplace), tokenId1), 0);
        assertEq(paymentToken.balanceOf(seller1), seller1InitialPayment + proceeds2);

        // STEP 5: Buyer1 buys the entire listing from seller2
        uint256 buyAmount3 = 500;
        uint256 totalPrice3 = buyAmount3 * 15 * 1e6;

        vm.startPrank(buyer1);
        paymentToken.approve(address(marketplace), totalPrice3);
        marketplace.buy(listingId2, buyAmount3);
        vm.stopPrank();

        Marketplace.Listing memory listing2 = marketplace.getListing(listingId2);
        assertFalse(listing2.active);
        assertEq(credit.balanceOf(buyer1, tokenId2), buyAmount3);
        assertEq(credit.balanceOf(address(marketplace), tokenId2), 0);

        // STEP 6: Seller2 lists more tokens, then cancels the listing
        vm.startPrank(seller2);
        uint256 listingId3 = marketplace.list(tokenId2, 300, 20 * 1e6, 1 days);
        assertEq(credit.balanceOf(address(marketplace), tokenId2), 300);
        marketplace.cancelListing(listingId3);
        vm.stopPrank();

        Marketplace.Listing memory listing3 = marketplace.getListing(listingId3);
        assertFalse(listing3.active);
        assertEq(credit.balanceOf(address(marketplace), tokenId2), 0);
        assertEq(credit.balanceOf(seller2, tokenId2), 500); // 1000 minted - 500 sold

        // STEP 7: Admin changes the fee, a new purchase reflects this
        vm.prank(admin);
        marketplace.setProtocolFeeBps(500); // 5% fee

        // Seller1 lists again
        vm.startPrank(seller1);
        uint256 listingId4 = marketplace.list(tokenId1, 100, 10 * 1e6, 1 days);
        vm.stopPrank();

        // Buyer1 buys
        uint256 buyAmount4 = 10;
        uint256 totalPrice4 = buyAmount4 * 10 * 1e6;
        uint256 newFee = (totalPrice4 * 500) / 10000; // 5%
        uint256 treasuryInitialBalance = paymentToken.balanceOf(treasury);

        vm.startPrank(buyer1);
        paymentToken.approve(address(marketplace), totalPrice4);
        marketplace.buy(listingId4, buyAmount4);
        vm.stopPrank();

        assertEq(paymentToken.balanceOf(treasury), treasuryInitialBalance + newFee);
    }
}
