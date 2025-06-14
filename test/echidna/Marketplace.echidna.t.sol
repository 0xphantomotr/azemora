// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Marketplace} from "../../src/marketplace/Marketplace.sol";
import {DynamicImpactCredit} from "../../src/core/DynamicImpactCredit.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Echidna test for the Marketplace contract
/// @notice This contract defines properties (invariants) that should always hold true
/// for the Marketplace, no matter what sequence of functions are called.
/// Echidna will try to break these properties.
contract MarketplaceEchidnaTest is Test {
    Marketplace internal marketplace;
    DynamicImpactCredit internal credit;
    ProjectRegistry internal registry;
    ERC20Mock internal paymentToken;

    // Echidna will use this to generate random users
    address[] internal users;

    // Constants for the test setup
    uint256 constant NUM_TOKENS = 10;
    uint256 constant NUM_USERS = 5;
    uint256 constant INITIAL_MINT_AMOUNT = 1000;
    uint256 constant INITIAL_PAYMENT_BALANCE = 1_000_000 ether;

    constructor() {
        // --- Deploy Logic & Proxies in correct order ---

        // 1. Deploy Registry (logic and proxy)
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryData = abi.encodeWithSelector(ProjectRegistry.initialize.selector);
        registry = ProjectRegistry(payable(address(new ERC1967Proxy(address(registryImpl), registryData))));

        // 2. Deploy Credit contract logic, passing it the *registry proxy* address
        DynamicImpactCredit creditImpl = new DynamicImpactCredit(address(registry));
        bytes memory creditData = abi.encodeWithSelector(creditImpl.initialize.selector, "contract_uri");
        credit = DynamicImpactCredit(payable(address(new ERC1967Proxy(address(creditImpl), creditData))));

        // 3. Deploy Payment Token
        paymentToken = new ERC20Mock();

        // 4. Deploy Marketplace (logic and proxy)
        Marketplace marketplaceImpl = new Marketplace();
        bytes memory marketplaceData =
            abi.encodeWithSelector(marketplaceImpl.initialize.selector, address(credit), address(paymentToken));
        marketplace = Marketplace(payable(address(new ERC1967Proxy(address(marketplaceImpl), marketplaceData))));

        // --- Grant Roles ---
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(this));
        registry.grantRole(registry.VERIFIER_ROLE(), address(this));

        // --- Create Users and Tokens ---
        for (uint256 i = 0; i < NUM_USERS; i++) {
            users.push(address(uint160(i + 1))); // Create non-zero user addresses
        }

        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            bytes32 projectId = keccak256(abi.encodePacked(i));
            registry.registerProject(projectId, "uri"); // Step 1: Register
            registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
            credit.mintCredits(address(this), projectId, INITIAL_MINT_AMOUNT, "token_uri");
        }

        // --- Distribute Assets ---
        // Give this test contract approval to manage its own tokens on the marketplace
        credit.setApprovalForAll(address(marketplace), true);

        // Give all our fake users some payment tokens and approve the marketplace
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            paymentToken.mint(users[i], INITIAL_PAYMENT_BALANCE);
            paymentToken.approve(address(marketplace), type(uint256).max);
            vm.stopPrank();
        }
    }

    // =================================================================
    //                           INVARIANTS
    // =================================================================

    /// @dev Property: An active listing must always have a price greater than zero.
    function echidna_active_listing_has_price() public view returns (bool) {
        uint256 counter = marketplace.listingIdCounter();
        for (uint256 i = 0; i < counter; i++) {
            (,,,, bool active, uint256 pricePerUnit,) = marketplace.listings(i);
            if (active) {
                if (pricePerUnit == 0) return false;
            }
        }
        return true;
    }

    /// @dev Property: An active listing's seller cannot be the zero address.
    function echidna_active_listing_has_seller() public view returns (bool) {
        uint256 counter = marketplace.listingIdCounter();
        for (uint256 i = 0; i < counter; i++) {
            (,, address seller,, bool active,,) = marketplace.listings(i);
            if (active) {
                if (seller == address(0)) return false;
            }
        }
        return true;
    }

    /// @dev Property: The marketplace contract's token balance for a given tokenId
    /// should equal the sum of all active listings for that tokenId.
    function echidna_marketplace_holds_listed_tokens() public view returns (bool) {
        uint256 listingCounter = marketplace.listingIdCounter();

        // Check this invariant for each token type we created.
        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            bytes32 projectId = keccak256(abi.encodePacked(i));
            uint256 currentTokenId = uint256(projectId);
            uint256 totalListedForToken = 0;

            // Sum up all active listings for the current tokenId.
            for (uint256 j = 0; j < listingCounter; j++) {
                (, uint256 listedTokenId,,, bool active,, uint256 amount) = marketplace.listings(j);
                if (active && listedTokenId == currentTokenId) {
                    totalListedForToken += amount;
                }
            }

            // The marketplace's balance should match the sum of active listings.
            if (credit.balanceOf(address(marketplace), currentTokenId) != totalListedForToken) {
                return false;
            }
        }

        return true;
    }

    // =================================================================
    //                      STATE-CHANGING FUNCTIONS
    // =================================================================
    // These wrappers guide Echidna to call the marketplace functions
    // with valid (or at least semi-valid) parameters.

    function list(uint256 tokenId, uint256 amount, uint256 price, uint256 duration) public {
        tokenId = constrain(tokenId, 0, NUM_TOKENS - 1);
        amount = constrain(amount, 1, INITIAL_MINT_AMOUNT); // list at least 1
        price = constrain(price, 1, 1000 ether); // price must be > 0
        duration = constrain(duration, 1, 365 days); // duration must be > 0

        bytes32 projectId = keccak256(abi.encodePacked(tokenId));
        uint256 realTokenId = uint256(projectId);

        // Ensure we don't try to list more than we have.
        uint256 balance = credit.balanceOf(address(this), realTokenId);
        if (amount > balance) {
            amount = balance;
        }
        if (amount == 0) return;

        marketplace.list(realTokenId, amount, price, duration);
    }

    function buy(uint256 listingId, uint256 amountToBuy) public {
        uint256 counter = marketplace.listingIdCounter();
        if (counter == 0) return;

        listingId = constrain(listingId, 0, counter - 1);
        address buyer = users[listingId % NUM_USERS]; // Pick a random user

        (
            , // id
            , // tokenId
            address seller,
            uint64 expiryTimestamp,
            bool active,
            uint256 pricePerUnit,
            uint256 amount
        ) = marketplace.listings(listingId);

        if (!active || expiryTimestamp < block.timestamp || seller == buyer) return;

        amountToBuy = constrain(amountToBuy, 1, amount);

        uint256 cost = amountToBuy * pricePerUnit;
        if (paymentToken.balanceOf(buyer) < cost) return;

        vm.prank(buyer);
        marketplace.buy(listingId, amountToBuy);
    }

    function cancelListing(uint256 listingId) public {
        uint256 counter = marketplace.listingIdCounter();
        if (counter == 0) return;
        listingId = constrain(listingId, 0, counter - 1);

        (,, address seller,, bool active,,) = marketplace.listings(listingId);
        if (seller != address(this) || !active) return; // Only contract can cancel its own ACTIVE listings

        marketplace.cancelListing(listingId);
    }

    // --- Helper function to constrain Echidna's random inputs ---
    function constrain(uint256 val, uint256 min, uint256 max) internal pure returns (uint256) {
        if (min >= max) {
            return min;
        }
        // Use modulo to wrap the value into the range [min, max]
        return (val % (max - min + 1)) + min;
    }
}
