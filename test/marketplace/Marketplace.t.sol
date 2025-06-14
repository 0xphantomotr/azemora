// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Minimal mock ERC20 to avoid dependency on forge-std/mocks
contract MockERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract MarketplaceTest is Test {
    // Core contracts
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    Marketplace marketplace;

    // Mock payment token
    MockERC20 paymentToken;

    // Users
    address admin = address(0xA11CE);
    address seller = address(0x5E11E);
    address buyer = address(0xB4BE);
    address verifier = address(0xC1E4);
    address dmrvManager = address(0xB01D);
    address treasury = address(0xFE35);

    // Project and Token IDs
    bytes32 projectId = keccak256("Test Project");
    uint256 tokenId;

    function setUp() public {
        tokenId = uint256(projectId);

        // --- Deploy Infrastructure ---
        // Deploy payment token and mint to buyer
        paymentToken = new MockERC20("Mock Payment", "MPAY", 18);
        vm.prank(address(this)); // Mint from test contract itself
        paymentToken.mint(buyer, 1_000_000 * 1e18); // 1M USDC

        vm.startPrank(admin);

        // 1. Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        ERC1967Proxy registryProxy =
            new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ()));
        registry = ProjectRegistry(address(registryProxy));
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // 2. Deploy DynamicImpactCredit
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        ERC1967Proxy creditProxy = new ERC1967Proxy(
            address(creditImpl),
            abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://contract-metadata.json", address(registry)))
        );
        credit = DynamicImpactCredit(address(creditProxy));
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), dmrvManager);

        // 3. Deploy Marketplace
        Marketplace marketplaceImpl = new Marketplace();
        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(
            address(marketplaceImpl), abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)))
        );
        marketplace = Marketplace(address(marketplaceProxy));
        marketplace.setTreasury(treasury);
        marketplace.setFee(250); // Set a 2.5% fee

        vm.stopPrank();

        // --- Prepare for tests ---
        // 1. Register and activate project
        vm.prank(seller);
        registry.registerProject(projectId, "ipfs://project.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        // 2. Mint some credits to the seller
        vm.prank(dmrvManager);
        credit.mintCredits(seller, projectId, 1000, "ipfs://credit.json");
    }

    // Helper to list an item
    function _list() internal returns (uint256 listingId) {
        vm.startPrank(seller);
        credit.setApprovalForAll(address(marketplace), true);
        listingId = marketplace.list(tokenId, 100, 5 * 1e6, 1 days);
        vm.stopPrank();
        return listingId;
    }

    // --- Tests ---

    function test_List() public {
        vm.startPrank(seller);
        credit.setApprovalForAll(address(marketplace), true);

        uint256 initialSellerBalance = credit.balanceOf(seller, tokenId);
        uint256 listingId = marketplace.list(tokenId, 100, 5 * 1e6, 1 days);
        vm.stopPrank();

        uint256 finalSellerBalance = credit.balanceOf(seller, tokenId);
        uint256 marketplaceBalance = credit.balanceOf(address(marketplace), tokenId);

        assertEq(initialSellerBalance - finalSellerBalance, 100, "Seller should send tokens to marketplace");
        assertEq(marketplaceBalance, 100, "Marketplace should receive tokens");

        Marketplace.Listing memory listing = marketplace.getListing(listingId);

        assertEq(listing.seller, seller);
        assertEq(listing.tokenId, tokenId);
        assertEq(listing.amount, 100);
        assertEq(listing.pricePerUnit, 5 * 1e6);
        assertTrue(listing.active);
    }

    function test_Buy() public {
        uint256 listingId = _list();
        uint256 amountToBuy = 50;
        uint256 pricePerUnit = 5 * 1e6;
        uint256 totalPrice = amountToBuy * pricePerUnit;
        uint256 fee = (totalPrice * 250) / 10000;
        uint256 sellerProceeds = totalPrice - fee;

        uint256 sellerInitialPaymentBalance = paymentToken.balanceOf(seller);
        uint256 treasuryInitialBalance = paymentToken.balanceOf(treasury);

        vm.prank(buyer);
        paymentToken.approve(address(marketplace), totalPrice);

        vm.prank(buyer);
        marketplace.buy(listingId, amountToBuy);

        // Check NFT balances
        assertEq(credit.balanceOf(address(marketplace), tokenId), 50);
        assertEq(credit.balanceOf(buyer, tokenId), amountToBuy);

        // Check payment balances
        assertEq(paymentToken.balanceOf(seller), sellerInitialPaymentBalance + sellerProceeds);
        assertEq(paymentToken.balanceOf(treasury), treasuryInitialBalance + fee);

        // Check listing state
        Marketplace.Listing memory listing = marketplace.getListing(listingId);
        assertEq(listing.amount, 100 - amountToBuy);
        assertTrue(listing.active);
    }

    function test_Buy_FullListing() public {
        uint256 listingId = _list();
        uint256 amountToBuy = 100;
        uint256 totalPrice = amountToBuy * 5 * 1e6;

        vm.prank(buyer);
        paymentToken.approve(address(marketplace), totalPrice);

        vm.prank(buyer);
        marketplace.buy(listingId, amountToBuy);

        Marketplace.Listing memory listing = marketplace.getListing(listingId);
        assertFalse(listing.active);
        assertEq(listing.amount, 0);
        assertEq(credit.balanceOf(address(marketplace), tokenId), 0);
    }

    function test_Buy_WithZeroFee() public {
        // --- Setup ---
        // Set fee to 0 to test the fee == 0 branch
        vm.prank(admin);
        marketplace.setFee(0);

        uint256 listingId = _list();
        uint256 amountToBuy = 50;
        uint256 pricePerUnit = 5 * 1e6;
        uint256 totalPrice = amountToBuy * pricePerUnit;

        uint256 sellerInitialPaymentBalance = paymentToken.balanceOf(seller);
        uint256 treasuryInitialBalance = paymentToken.balanceOf(treasury);

        // --- Action ---
        vm.prank(buyer);
        paymentToken.approve(address(marketplace), totalPrice);

        vm.prank(buyer);
        marketplace.buy(listingId, amountToBuy);

        // --- Assertions ---
        // Check NFT balances
        assertEq(credit.balanceOf(buyer, tokenId), amountToBuy, "Buyer should receive the NFTs");

        // Check payment balances: Seller gets full amount, treasury gets nothing
        assertEq(
            paymentToken.balanceOf(seller),
            sellerInitialPaymentBalance + totalPrice,
            "Seller should receive full payment when fee is zero"
        );
        assertEq(
            paymentToken.balanceOf(treasury),
            treasuryInitialBalance,
            "Treasury balance should not change when fee is zero"
        );
    }

    function test_CancelListing() public {
        uint256 listingId = _list();
        uint256 sellerInitialBalance = credit.balanceOf(seller, tokenId);
        uint256 marketplaceBalance = credit.balanceOf(address(marketplace), tokenId);
        assertEq(marketplaceBalance, 100);

        vm.prank(seller);
        marketplace.cancelListing(listingId);

        Marketplace.Listing memory listing = marketplace.getListing(listingId);
        assertFalse(listing.active);
        assertEq(credit.balanceOf(seller, tokenId), sellerInitialBalance + 100);
        assertEq(credit.balanceOf(address(marketplace), tokenId), 0);
    }

    function test_CancelExpiredListing() public {
        uint256 listingId = _list(); // Lists with 1 day expiry
        uint256 sellerInitialBalance = credit.balanceOf(seller, tokenId);

        // Fast-forward time past the expiry
        vm.warp(block.timestamp + 2 days);

        // Anyone can cancel an expired listing
        vm.prank(buyer);
        marketplace.cancelExpiredListing(listingId);

        // Check listing is inactive and seller got their tokens back
        Marketplace.Listing memory listing = marketplace.getListing(listingId);
        assertFalse(listing.active);
        assertEq(credit.balanceOf(seller, tokenId), sellerInitialBalance + 100);
        assertEq(credit.balanceOf(address(marketplace), tokenId), 0);
    }

    function test_Fail_CancelExpiredOnNonExpiredListing() public {
        uint256 listingId = _list(); // Lists with 1 day expiry

        // Try to cancel immediately
        vm.prank(buyer);
        vm.expectRevert("Marketplace: Listing not expired yet");
        marketplace.cancelExpiredListing(listingId);
    }

    function test_UpdateListingPrice() public {
        uint256 listingId = _list();
        uint256 newPrice = 10 * 1e6;

        vm.prank(seller);
        marketplace.updateListingPrice(listingId, newPrice);

        Marketplace.Listing memory listing = marketplace.getListing(listingId);
        assertEq(listing.pricePerUnit, newPrice);
    }

    function test_Fail_UpdateListingPrice_NotSeller() public {
        uint256 listingId = _list();

        vm.prank(buyer); // Use a different user
        vm.expectRevert("Marketplace: Not the seller");
        marketplace.updateListingPrice(listingId, 10 * 1e6);
    }

    function test_Fail_UpdateListingPrice_InactiveListing() public {
        uint256 listingId = _list();

        // Cancel the listing to make it inactive
        vm.prank(seller);
        marketplace.cancelListing(listingId);

        // Try to update the price
        vm.prank(seller);
        vm.expectRevert("Marketplace: Listing not active");
        marketplace.updateListingPrice(listingId, 10 * 1e6);
    }

    function test_Fail_UpdateListingPrice_ZeroPrice() public {
        uint256 listingId = _list();

        vm.prank(seller);
        vm.expectRevert("Marketplace: Price must be > 0");
        marketplace.updateListingPrice(listingId, 0);
    }

    function test_Fail_SetTreasury_ToZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("Marketplace: Treasury address cannot be zero");
        marketplace.setTreasury(address(0));
    }

    function test_Fail_SetFee_AboveCap() public {
        vm.prank(admin);
        vm.expectRevert("Marketplace: Fee cannot exceed 100%");
        marketplace.setFee(10001); // 100.01%
    }

    function test_Fail_ListWithZeroAmount() public {
        vm.prank(seller);
        credit.setApprovalForAll(address(marketplace), true);
        vm.expectRevert("Marketplace: Amount must be > 0");
        marketplace.list(tokenId, 0, 5 * 1e6, 1 days);
    }

    function test_Fail_ListWithZeroPrice() public {
        vm.prank(seller);
        credit.setApprovalForAll(address(marketplace), true);
        vm.expectRevert("Marketplace: Price must be > 0");
        marketplace.list(tokenId, 100, 0, 1 days);
    }

    function test_Fail_ListWithZeroExpiry() public {
        vm.prank(seller);
        credit.setApprovalForAll(address(marketplace), true);
        vm.expectRevert("Marketplace: Expiry must be > 0");
        marketplace.list(tokenId, 100, 5 * 1e6, 0);
    }

    function test_Fail_BuyExpiredListing() public {
        uint256 listingId = _list(); // Lists with 1 day expiry

        // Fast-forward time past the expiry
        vm.warp(block.timestamp + 2 days);

        vm.prank(buyer);
        vm.expectRevert("Marketplace: Listing expired");
        marketplace.buy(listingId, 10);
    }

    function test_Fail_BuyZeroAmount() public {
        uint256 listingId = _list();
        vm.prank(buyer);
        vm.expectRevert("Marketplace: Amount must be > 0");
        marketplace.buy(listingId, 0);
    }

    function test_Fail_BuyMoreThanListed() public {
        uint256 listingId = _list(); // Lists 100 items
        vm.prank(buyer);
        vm.expectRevert("Marketplace: Not enough items in listing");
        marketplace.buy(listingId, 101);
    }

    /* ---------- Event Tests ---------- */

    function test_EmitFeePaidEvent() public {
        uint256 listingId = _list();
        uint256 amountToBuy = 50;
        uint256 totalPrice = amountToBuy * 5 * 1e6;
        uint256 fee = (totalPrice * 250) / 10000;

        vm.prank(buyer);
        paymentToken.approve(address(marketplace), totalPrice);

        vm.expectEmit(true, true, true, true);
        emit Marketplace.FeePaid(treasury, fee);

        vm.prank(buyer);
        marketplace.buy(listingId, amountToBuy);
    }

    /* ---------- Access Control & Failure Tests ---------- */

    function test_Fail_ListWithoutApproval() public {
        vm.startPrank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC1155MissingApprovalForAll(address,address)")), address(marketplace), seller
            )
        );
        marketplace.list(tokenId, 100, 5 * 1e6, 1 days);
        vm.stopPrank();
    }

    function test_Fail_BuyWithInsufficientPayment() public {
        uint256 listingId = _list();

        vm.prank(buyer);
        // Approve less than required
        paymentToken.approve(address(marketplace), 10 * 1e6);

        vm.prank(buyer);
        vm.expectRevert("ERC20: insufficient allowance");
        marketplace.buy(listingId, 50);
    }

    function test_Fail_NonSellerCannotCancel() public {
        uint256 listingId = _list();
        vm.prank(buyer);
        vm.expectRevert("Marketplace: Not the seller");
        marketplace.cancelListing(listingId);
    }

    function test_Fail_BuyWithInsufficientBalance() public {
        uint256 listingId = _list();
        uint256 amountToBuy = 50;
        uint256 pricePerUnit = 5 * 1e6;
        uint256 totalPrice = amountToBuy * pricePerUnit;

        address brokeBuyer = address(0xDEAD);

        vm.prank(brokeBuyer);
        paymentToken.approve(address(marketplace), totalPrice);

        vm.prank(brokeBuyer);
        // The Marketplace contract has its own balance check that runs before the ERC20 transfer.
        vm.expectRevert("Marketplace: Insufficient balance");
        marketplace.buy(listingId, amountToBuy);
    }

    function test_Fail_GetNonExistentListing() public {
        uint256 nonExistentListingId = 999;
        vm.expectRevert("Marketplace: Listing not found");
        marketplace.getListing(nonExistentListingId);
    }

    /* ---------- Pausable Tests ---------- */

    function test_PauseAndUnpause() public {
        bytes32 pauserRole = marketplace.PAUSER_ROLE();

        vm.startPrank(admin);
        // Admin can pause and unpause
        marketplace.pause();
        assertTrue(marketplace.paused());
        marketplace.unpause();
        assertFalse(marketplace.paused());
        vm.stopPrank();

        // Non-pauser cannot pause
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), seller, pauserRole
            )
        );
        marketplace.pause();
    }

    function test_RevertsWhenPaused() public {
        uint256 listingId = _list();

        vm.startPrank(admin);
        marketplace.pause();
        vm.stopPrank();

        // Check key functions revert when paused
        bytes4 expectedRevert = bytes4(keccak256("EnforcedPause()"));

        vm.prank(seller);
        vm.expectRevert(expectedRevert);
        marketplace.list(tokenId, 10, 1e6, 1 days);

        vm.prank(buyer);
        vm.expectRevert(expectedRevert);
        marketplace.buy(listingId, 1);

        vm.prank(seller);
        vm.expectRevert(expectedRevert);
        marketplace.cancelListing(listingId);

        vm.prank(seller);
        vm.expectRevert(expectedRevert);
        marketplace.updateListingPrice(listingId, 6e6);
    }
}
