// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./Marketplace.t.sol"; // Re-use mocks
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/marketplace/Marketplace.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketplaceFuzzTest is Test {
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    Marketplace marketplace;
    MockERC20 paymentToken;

    address admin = address(0xA11CE);
    address verifier = address(0xC1E4);
    address dmrvManager = address(0xB01D);
    address treasury = address(0xFE35);
    address seller = address(0x5E11E1);
    address buyer = address(0xB4BE1);

    function setUp() public {
        // --- Deploy Infrastructure ---
        paymentToken = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(address(this));
        paymentToken.mint(buyer, 1_000_000_000 * 1e6); // 1B USDC for fuzzing

        vm.startPrank(admin);

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
        marketplace.setFee(250); // 2.5% fee

        vm.stopPrank();
    }

    function testFuzz_ListAndBuy(uint64 seed, uint256 listAmount, uint256 buyAmount, uint256 price) public {
        bytes32 projectId = keccak256(abi.encodePacked("project", seed));
        uint256 tokenId = uint256(projectId);

        // --- Setup State ---
        uint256 mintAmount = 1_000_000;
        // 1. Activate project and mint tokens to seller
        vm.prank(seller);
        registry.registerProject(projectId, "ipfs://fuzz.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        vm.prank(dmrvManager);
        credit.mintCredits(seller, projectId, mintAmount, "ipfs://fuzz-c.json");

        // 2. Bound inputs to be reasonable
        listAmount = bound(listAmount, 1, mintAmount);
        buyAmount = bound(buyAmount, 1, listAmount);
        price = bound(price, 1, 1_000_000 * 1e6); // Price up to 1M USDC

        // 3. Assume the buyer can afford the purchase to avoid reverts
        uint256 totalPrice = buyAmount * price;
        vm.assume(totalPrice < paymentToken.balanceOf(buyer));

        // --- Execute Actions ---
        // 4. Seller lists the item
        vm.startPrank(seller);
        credit.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(tokenId, listAmount, price, 1 days);
        vm.stopPrank();

        // 5. Buyer approves payment and buys the item
        uint256 fee = (totalPrice * 250) / 10000;
        uint256 sellerProceeds = totalPrice - fee;

        vm.startPrank(buyer);
        paymentToken.approve(address(marketplace), type(uint256).max);
        marketplace.buy(listingId, buyAmount);
        vm.stopPrank();

        // --- Assert Final State ---
        // Assert NFT balances
        assertEq(credit.balanceOf(seller, tokenId), mintAmount - listAmount, "Seller NFT balance incorrect");
        assertEq(credit.balanceOf(buyer, tokenId), buyAmount, "Buyer NFT balance incorrect");
        assertEq(
            credit.balanceOf(address(marketplace), tokenId), listAmount - buyAmount, "Marketplace NFT balance incorrect"
        );

        // Assert payment token balances
        assertEq(paymentToken.balanceOf(seller), sellerProceeds, "Seller payment balance incorrect");
    }
}
