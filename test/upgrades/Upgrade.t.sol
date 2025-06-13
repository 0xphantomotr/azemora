// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/marketplace/Marketplace.sol";
import "./MarketplaceV2.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeTest is Test {
    // Contracts
    Marketplace marketplace; // The proxy, which we will interact with
    ERC20Mock paymentToken;
    address creditContract; // Mocked as an address for this test

    // Users
    address admin = makeAddr("admin");
    address otherUser = makeAddr("otherUser");

    function setUp() public {
        creditContract = makeAddr("creditContract");
        paymentToken = new ERC20Mock();

        vm.startPrank(admin);

        // Deploy V1 Marketplace implementation and proxy
        Marketplace marketplaceV1Impl = new Marketplace();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(marketplaceV1Impl), abi.encodeCall(Marketplace.initialize, (creditContract, address(paymentToken)))
        );
        marketplace = Marketplace(address(proxy)); // Point our interface to the proxy address

        // Set initial state on V1 that we will check after the upgrade
        marketplace.setFee(250); // 2.5% fee

        vm.stopPrank();
    }

    function test_upgradeMarketplace_preservesStateAndRoles() public {
        // --- 1. Pre-Upgrade Assertions ---
        assertEq(marketplace.feeBps(), 250, "Pre-upgrade feeBps should be 250");
        assertTrue(
            marketplace.hasRole(marketplace.DEFAULT_ADMIN_ROLE(), admin), "Admin should have admin role before upgrade"
        );

        // --- 2. Deploy V2 and Upgrade ---
        vm.startPrank(admin);
        MarketplaceV2 marketplaceV2Impl = new MarketplaceV2();
        marketplace.upgradeToAndCall(address(marketplaceV2Impl), ""); // No call data needed for this simple upgrade
        vm.stopPrank();

        // --- 3. Post-Upgrade Assertions ---

        // Cast the proxy address to the V2 interface to access new functions
        MarketplaceV2 marketplaceV2 = MarketplaceV2(address(marketplace));

        // Check that state is preserved
        assertEq(marketplaceV2.feeBps(), 250, "Post-upgrade feeBps should still be 250");

        // Check that roles are preserved
        assertTrue(
            marketplaceV2.hasRole(marketplace.DEFAULT_ADMIN_ROLE(), admin),
            "Admin should still have admin role after upgrade"
        );

        // Check that new V2 functionality works
        vm.prank(admin);
        marketplaceV2.setVersion(2);
        assertEq(marketplaceV2.version(), 2, "V2 function 'setVersion' should work after upgrade");

        // Check that old functions still work on the new implementation
        vm.prank(admin);
        marketplaceV2.setFee(500);
        assertEq(marketplaceV2.feeBps(), 500, "V1 function 'setFee' should still work after upgrade");

        // Check that a non-admin cannot call admin functions
        bytes4 expectedError = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        vm.expectRevert(abi.encodeWithSelector(expectedError, otherUser, marketplace.DEFAULT_ADMIN_ROLE()));
        vm.prank(otherUser);
        marketplaceV2.setFee(1000);
    }
}
