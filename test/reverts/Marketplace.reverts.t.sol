// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Minimal mock ERC20 for testing reverts
contract MockERC20ForReverts is Test {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) public {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (allowance[from][msg.sender] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }
}

// Minimal mock ERC1155 for testing reverts
contract MockERC1155ForReverts is Test {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function safeTransferFrom(address, address to, uint256 id, uint256 amount, bytes memory) public {
        balanceOf[to][id] += amount;
    }

    function setApprovalForAll(address, bool) public {}
}

contract MarketplaceRevertsTest is Test {
    Marketplace marketplace;
    MockERC1155ForReverts credit;
    MockERC20ForReverts paymentToken;

    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address otherUser = makeAddr("otherUser");

    uint256 tokenId = 1;
    uint256 listingId;

    function setUp() public {
        credit = new MockERC1155ForReverts();
        paymentToken = new MockERC20ForReverts();

        vm.startPrank(admin);
        Marketplace marketplaceImpl = new Marketplace();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(marketplaceImpl),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)))
                )
            )
        );
        vm.stopPrank();

        // Create a default listing for use in tests
        vm.prank(seller);
        listingId = marketplace.list(tokenId, 100, 10 ether, 1 days);
    }

    // --- list ---

    function test_revert_list_zeroAmount() public {
        vm.expectRevert(Marketplace__ZeroAmount.selector);
        vm.prank(seller);
        marketplace.list(tokenId, 0, 10 ether, 1 days);
    }

    function test_revert_list_zeroPrice() public {
        vm.expectRevert(Marketplace__ZeroPrice.selector);
        vm.prank(seller);
        marketplace.list(tokenId, 100, 0, 1 days);
    }

    // --- buy ---

    function test_revert_buy_inactiveListing() public {
        // Cancel the listing first
        vm.prank(seller);
        marketplace.cancelListing(listingId);

        vm.expectRevert(Marketplace__ListingNotActive.selector);
        vm.prank(buyer);
        marketplace.buy(listingId, 10);
    }

    function test_revert_buy_expiredListing() public {
        vm.warp(block.timestamp + 2 days); // Fast forward time
        vm.expectRevert(Marketplace__ListingExpired.selector);
        vm.prank(buyer);
        marketplace.buy(listingId, 10);
    }

    function test_revert_buy_insufficientItems() public {
        vm.expectRevert(Marketplace__NotEnoughItemsInListing.selector);
        vm.prank(buyer);
        marketplace.buy(listingId, 101); // Try to buy more than listed
    }

    function test_revert_buy_insufficientBalance() public {
        // Buyer has 0 payment tokens
        vm.expectRevert(Marketplace__InsufficientBalance.selector);
        vm.prank(buyer);
        marketplace.buy(listingId, 10);
    }

    // --- cancelListing ---

    function test_revert_cancelListing_notSeller() public {
        vm.expectRevert(Marketplace__NotTheSeller.selector);
        vm.prank(otherUser);
        marketplace.cancelListing(listingId);
    }

    // --- updateListingPrice ---

    function test_revert_updateListingPrice_notSeller() public {
        vm.expectRevert(Marketplace__NotTheSeller.selector);
        vm.prank(otherUser);
        marketplace.updateListingPrice(listingId, 5 ether);
    }

    function test_revert_updateListingPrice_inactiveListing() public {
        vm.prank(seller);
        marketplace.cancelListing(listingId);

        vm.expectRevert(Marketplace__ListingNotActive.selector);
        vm.prank(seller);
        marketplace.updateListingPrice(listingId, 5 ether);
    }

    // --- Admin functions ---

    function test_revert_setTreasury_notAdmin() public {
        bytes4 expectedError = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        vm.expectRevert(abi.encodeWithSelector(expectedError, otherUser, marketplace.DEFAULT_ADMIN_ROLE()));
        vm.prank(otherUser);
        marketplace.setTreasury(otherUser);
    }

    function test_revert_setFee_notAdmin() public {
        bytes4 expectedError = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        vm.expectRevert(abi.encodeWithSelector(expectedError, otherUser, marketplace.DEFAULT_ADMIN_ROLE()));
        vm.prank(otherUser);
        marketplace.setProtocolFeeBps(100);
    }
}
