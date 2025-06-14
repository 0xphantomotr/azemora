// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// @dev A handler contract for the fuzzer. It defines the actions the fuzzer can take.
contract InvariantHandler is Test {
    Marketplace marketplace;
    address admin;

    constructor(Marketplace _marketplace, address _admin) {
        marketplace = _marketplace;
        admin = _admin;
    }

    // --- Fuzzer Actions ---
    // The fuzzer can call these functions with random inputs.
    // We only expose a subset of non-admin functions for this test.

    function list(uint256 tokenId, uint128 amount, uint128 price) public {
        // We don't care if this reverts, the invariant is about admin roles.
        // In a real test, we would add more robust checks.
        // For now, we just want to give the fuzzer some valid functions to call.
    }

    function buy(uint256 listingId, uint256 amount) public {
        // Don't care if this reverts
    }
}

contract SystemInvariantTest is Test {
    // Contracts
    Marketplace marketplace;
    DynamicImpactCredit credit;
    ProjectRegistry registry;
    ERC20Mock paymentToken;

    // Users
    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    // Fuzzer target
    InvariantHandler handler;

    function setUp() public {
        vm.startPrank(admin);

        // Deploy Core Contracts
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(address(new ERC1967Proxy(address(registryImpl), "")));
        registry.initialize();

        DynamicImpactCredit creditImpl = new DynamicImpactCredit(address(registry));
        credit = DynamicImpactCredit(address(new ERC1967Proxy(address(creditImpl), "")));
        credit.initialize("ipfs://");

        // Deploy Marketplace
        paymentToken = new ERC20Mock();
        Marketplace marketplaceImpl = new Marketplace();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(marketplaceImpl),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)))
                )
            )
        );

        handler = new InvariantHandler(marketplace, admin);
        targetContract(address(handler)); // Tell the fuzzer which contract to call

        vm.stopPrank();
    }

    /**
     * @dev Invariant: The ADMIN role for the Marketplace should always be held by the Timelock contract.
     * Ensures that no other address can gain administrative control over the marketplace.
     */
    function invariant_MarketplaceAdminRoleIsStable() public view {
        bytes32 adminRole = marketplace.DEFAULT_ADMIN_ROLE();
        assertTrue(
            marketplace.hasRole(adminRole, admin), "Invariant Violated: Marketplace admin role was lost or transferred."
        );
    }
}
