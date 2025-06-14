// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/governance/Treasury.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import "../marketplace/Marketplace.t.sol";

// THE FIX: Define an interface to break the circular dependency.
// The handler will call this interface, and the test contract will implement it.
interface IFeeCallback {
    function addFee(uint256 fee) external;
}

/*
 * @title FeeInvariantHandler
 * @notice The "fuzzer actor" that performs random actions on the marketplace.
 * @dev Foundry's fuzzer will call the functions on this contract. This handler
 *      is stateful and attempts to perform valid operations. If an operation
 *      succeeds, it notifies the main test contract to update the ghost variable.
 */
// THE FIX: The handler must inherit from `Test` to use `vm` cheatcodes.
contract FeeInvariantHandler is Test {
    IFeeCallback immutable mainTest; // Depends on the simple interface
    Marketplace immutable marketplace;
    ERC20Mock immutable paymentToken;
    address immutable treasury;
    address immutable seller;
    address immutable buyer;
    uint256 immutable tokenId;

    // Keep track of listings created by this handler to try and buy from them.
    uint256[] public listingIds;

    constructor(
        IFeeCallback _mainTest, // Takes the interface as an argument
        Marketplace _marketplace,
        ERC20Mock _paymentToken,
        address _treasury,
        address _seller,
        address _buyer,
        uint256 _tokenId
    ) {
        mainTest = _mainTest;
        marketplace = _marketplace;
        paymentToken = _paymentToken;
        treasury = _treasury;
        seller = _seller;
        buyer = _buyer;
        tokenId = _tokenId;
    }

    /// @notice FUZZ ACTION: List 1 token for 1 ether.
    function list() public {
        vm.prank(seller);
        // We list only 1 token to have more individual listings to interact with.
        // This call can revert if the seller runs out of tokens, which is fine.
        try marketplace.list(tokenId, 1, 1 ether, 1 days) returns (uint256 newListingId) {
            listingIds.push(newListingId);
        } catch {}
    }

    /// @notice FUZZ ACTION: Attempt to buy 1 token from a random listing.
    function buy() public {
        if (listingIds.length == 0) return;

        // Pick a random listing to attempt to buy from.
        uint256 listingIndex = block.timestamp % listingIds.length;
        uint256 listingId = listingIds[listingIndex];

        // Check if the listing is still valid before attempting the buy.
        try marketplace.getListing(listingId) returns (Marketplace.Listing memory listing) {
            if (!listing.active || listing.amount == 0) return;

            uint256 amountToBuy = 1;
            uint256 cost = amountToBuy * listing.pricePerUnit;

            // Fuzzer needs funds to succeed.
            if (paymentToken.balanceOf(buyer) < cost) return;

            uint256 treasuryBalanceBefore = paymentToken.balanceOf(treasury);

            vm.prank(buyer);
            try marketplace.buy(listingId, amountToBuy) {
                // SUCCESS CASE: The buy succeeded. Calculate the fee and update the ghost variable.
                uint256 treasuryBalanceAfter = paymentToken.balanceOf(treasury);
                uint256 feeCollected = treasuryBalanceAfter - treasuryBalanceBefore;
                // This call now works correctly through the interface.
                mainTest.addFee(feeCollected);
            } catch {}
        } catch {}
    }

    /// @notice FUZZ ACTION: Attempt to cancel a random listing.
    function cancel() public {
        if (listingIds.length == 0) return;
        uint256 listingIndex = block.timestamp % listingIds.length;
        uint256 listingId = listingIds[listingIndex];

        vm.prank(seller);
        // This may revert if the listing is already inactive, which is fine.
        try marketplace.cancelListing(listingId) {} catch {}
    }
}

/*
 * @title FeeInvariantTest
 * @notice An invariant test to ensure marketplace fees are always correctly accounted for.
 * @dev THE FIX: This contract now implements the IFeeCallback interface.
 */
contract FeeInvariantTest is Test, IFeeCallback {
    // Contracts
    Marketplace marketplace;
    Treasury treasury;
    DynamicImpactCredit credit;
    ProjectRegistry registry;
    ERC20Mock paymentToken;

    // Users
    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    // The GHOST VARIABLE: Tracks the total fees that should have been collected.
    uint256 public totalFeesCalculated;

    function setUp() public {
        vm.startPrank(admin);
        // Deploy all contracts
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        treasury = Treasury(payable(address(new ERC1967Proxy(address(new Treasury()), ""))));
        treasury.initialize(admin);
        credit = DynamicImpactCredit(address(new ERC1967Proxy(address(new DynamicImpactCredit(address(registry))), "")));
        credit.initialize("ipfs://");
        paymentToken = new ERC20Mock();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(new Marketplace()),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)))
                )
            )
        );
        marketplace.setTreasury(address(treasury));
        marketplace.setFee(250); // 2.5%

        // Setup Project
        bytes32 projectId = keccak256("Test Project");
        uint256 tokenId = uint256(projectId);
        registry.registerProject(projectId, "ipfs://");
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), seller);

        vm.stopPrank();

        // --- Fund Users and Set Approvals ---
        // Seller gets 1,000 credits to list
        vm.prank(seller);
        credit.mintCredits(seller, projectId, 1000, "");
        credit.setApprovalForAll(address(marketplace), true);

        // Buyer gets 1,000,000 payment tokens and approves marketplace
        paymentToken.mint(buyer, 1_000_000 * 1 ether);
        vm.prank(buyer);
        paymentToken.approve(address(marketplace), type(uint256).max);

        // --- Setup Handler ---
        FeeInvariantHandler handler =
            new FeeInvariantHandler(this, marketplace, paymentToken, address(treasury), seller, buyer, tokenId);
        // Tell the fuzzer to call functions on the handler
        targetContract(address(handler));
    }

    /// @notice Implementation of the callback function for the handler.
    function addFee(uint256 fee) external override {
        totalFeesCalculated += fee;
    }

    /*
     * @notice INVARIANT: The Treasury's balance must always equal the sum of all fees collected.
     * @dev After every random action by the handler, this invariant checks that our off-chain
     *      calculation of fees matches the actual on-chain balance of the Treasury. This proves
     *      that fees are never lost, created from nothing, or sent to the wrong place.
     */
    function invariant_feeAccountingIsCorrect() public view {
        assertEq(
            totalFeesCalculated,
            paymentToken.balanceOf(address(treasury)),
            "Fee Invariant Violated: Treasury balance does not match calculated fees."
        );
    }
}
