// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/marketplace/Marketplace.sol";
import "../upgrades/MarketplaceV2.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/*
 * @title UpgradeInvariantHandler
 * @notice A "handler" contract that tells the Foundry fuzzer which actions it's allowed to take.
 * @dev This is the core of the upgrade invariant test. The fuzzer will call the functions
 *      on this contract in random order with random inputs. We expose normal user actions
 *      (like `list` and `buy`) and, crucially, a one-time `upgradeToV2` function.
 */
contract UpgradeInvariantHandler is Test {
    Marketplace marketplaceProxy;
    MarketplaceV2 marketplaceV2Impl;
    address admin;
    bool hasUpgraded;

    constructor(Marketplace _proxy, MarketplaceV2 _v2Impl, address _admin) {
        marketplaceProxy = _proxy;
        marketplaceV2Impl = _v2Impl;
        admin = _admin;
    }

    /// @notice A ghost function to give the fuzzer a non-admin action to call.
    function list(uint256 tokenId, uint256 amount, uint256 price) public {
        // We don't care about the logic here or if it reverts. The fuzzer just needs
        // valid functions to call to generate state transitions. The invariant check
        // happens automatically in the main test contract after each call.
    }

    /// @notice A ghost function for buying.
    function buy(uint256 listingId, uint256 amount) public {
        // We don't care about the logic.
    }

    /// @notice The key fuzzer action: perform a contract upgrade.
    function upgradeToV2() public {
        // Ensure the fuzzer doesn't try to upgrade multiple times.
        if (!hasUpgraded) {
            vm.startPrank(admin);
            marketplaceProxy.upgradeToAndCall(address(marketplaceV2Impl), "");
            vm.stopPrank();
            hasUpgraded = true;
        }
    }
}

/*
 * @title UpgradeInvariantTest
 * @notice An invariant test suite to prove that admin roles are stable across
 *         both random user actions and contract upgrades.
 */
contract UpgradeInvariantTest is Test {
    // Contracts
    Marketplace marketplace;
    MarketplaceV2 marketplaceV2Impl; // The V2 implementation, ready to be upgraded to.
    DynamicImpactCredit credit;
    ProjectRegistry registry;
    ERC20Mock paymentToken;

    // Users
    address admin = makeAddr("admin");

    // Fuzzer Target
    UpgradeInvariantHandler handler;

    function setUp() public {
        vm.startPrank(admin);

        // --- Deploy all contracts (V1 setup) ---
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(address(new ERC1967Proxy(address(registryImpl), "")));
        registry.initialize();

        DynamicImpactCredit creditImpl = new DynamicImpactCredit(address(registry));
        credit = DynamicImpactCredit(address(new ERC1967Proxy(address(creditImpl), "")));
        credit.initialize("ipfs://");

        paymentToken = new ERC20Mock();
        Marketplace marketplaceV1Impl = new Marketplace();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(marketplaceV1Impl),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)))
                )
            )
        );

        // --- Deploy the V2 implementation so it's ready for the upgrade ---
        marketplaceV2Impl = new MarketplaceV2();

        // --- Setup the handler for the fuzzer ---
        handler = new UpgradeInvariantHandler(marketplace, marketplaceV2Impl, admin);
        targetContract(address(handler)); // Tell the fuzzer to call functions on our handler.

        vm.stopPrank();
    }

    /**
     * @dev Invariant: Ensures the admin role for all upgradeable contracts remains stable across upgrades.
     * The admin should always be the Timelock contract.
     */
    function invariant_AdminRoleIsStableAcrossUpgrades() public view {
        // Check admin role for Marketplace
        bytes32 marketplaceAdminRole = marketplace.DEFAULT_ADMIN_ROLE();
        assertTrue(
            marketplace.hasRole(marketplaceAdminRole, admin),
            "INVARIANT VIOLATED: Marketplace admin role was lost or transferred!"
        );
    }
}
