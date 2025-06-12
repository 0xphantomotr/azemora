// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/*
 * @title MaliciousERC20
 * @notice A malicious ERC20 token designed to perform a re-entrancy attack.
 * @dev It overrides `transferFrom` to call back into the Marketplace's `buy` function.
 */
contract MaliciousERC20 is ERC20Mock {
    Marketplace public marketplace;
    uint256 public listingId;
    uint256 public attackAmount;
    uint256 public callCount = 0;

    function setAttack(Marketplace _marketplace, uint256 _listingId, uint256 _attackAmount) external {
        marketplace = _marketplace;
        listingId = _listingId;
        attackAmount = _attackAmount;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        callCount++;
        _transfer(from, to, amount);
        if (address(marketplace) != address(0)) {
            marketplace.buy(listingId, attackAmount);
        }
        return true;
    }
}

/*
 * @title MarketplaceSecurityTest
 * @notice A test suite for advanced security vulnerabilities in the Marketplace.
 */
contract MarketplaceSecurityTest is Test {
    Marketplace marketplace;
    DynamicImpactCredit credit;
    ProjectRegistry registry;
    MaliciousERC20 maliciousPaymentToken;

    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address attacker = makeAddr("attacker");
    bytes32 testProjectId;
    uint256 tokenId;

    function setUp() public {
        vm.startPrank(admin);
        registry = ProjectRegistry(address(new ERC1967Proxy(address(new ProjectRegistry()), "")));
        registry.initialize();
        credit = DynamicImpactCredit(address(new ERC1967Proxy(address(new DynamicImpactCredit()), "")));
        credit.initialize("ipfs://", address(registry));

        maliciousPaymentToken = new MaliciousERC20();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(new Marketplace()),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(maliciousPaymentToken)))
                )
            )
        );

        testProjectId = keccak256("Test Project");
        tokenId = uint256(testProjectId);
        registry.registerProject(testProjectId, "ipfs://");
        registry.setProjectStatus(testProjectId, ProjectRegistry.ProjectStatus.Active);

        credit.grantRole(credit.DMRV_MANAGER_ROLE(), seller);
        vm.stopPrank();
    }

    function test_revert_reentrancyOnBuy_viaMaliciousERC20() public {
        // --- 1. Setup the Scenario ---
        uint256 listAmount = 100;
        uint256 pricePerUnit = 1 ether;
        uint256 attackerBuyAmount = 10;
        uint256 attackCost = attackerBuyAmount * pricePerUnit;

        // --- Seller Actions ---
        // Use vm.startPrank to ensure all subsequent calls are from the seller.
        vm.startPrank(seller);
        // 1. Seller mints their own tokens.
        credit.mintCredits(seller, testProjectId, listAmount, "");
        // 2. Seller approves the marketplace.
        credit.setApprovalForAll(address(marketplace), true);
        // 3. Seller lists the tokens.
        uint256 listingId = marketplace.list(tokenId, listAmount, pricePerUnit, 1 days);
        vm.stopPrank();

        // --- 2. Setup the Attacker ---
        maliciousPaymentToken.mint(attacker, attackCost * 2);
        maliciousPaymentToken.setAttack(marketplace, listingId, attackerBuyAmount);
        vm.prank(attacker);
        maliciousPaymentToken.approve(address(marketplace), type(uint256).max);

        // --- 3. Execute the Attack ---
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vm.prank(attacker);
        marketplace.buy(listingId, attackerBuyAmount);

        // --- 4. Post-Attack State Verification ---
        // The `buy` transaction was reverted, so the state should be exactly as it was
        // after the `list` call completed.

        // The listing itself is unchanged.
        Marketplace.Listing memory listing = marketplace.getListing(listingId);
        assertEq(listing.amount, listAmount, "Listing amount should be unchanged");

        // The seller should have 0 tokens, as they are held in custody by the marketplace.
        assertEq(credit.balanceOf(seller, tokenId), 0, "Seller balance should be 0 as tokens are in custody");

        // The marketplace should still hold the 100 tokens in custody.
        assertEq(credit.balanceOf(address(marketplace), tokenId), listAmount, "Marketplace should retain custody of tokens");

        // The attacker's funds should be untouched.
        assertEq(maliciousPaymentToken.balanceOf(attacker), attackCost * 2, "Attacker token balance should be unchanged");
    }
} 