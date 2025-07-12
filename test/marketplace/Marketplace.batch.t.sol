// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "../mocks/MockERC20.sol";

contract MarketplaceBatchTest is Test {
    // --- Contracts ---
    Marketplace internal marketplace;
    DynamicImpactCredit internal creditToken;
    ProjectRegistry internal projectRegistry;
    MockERC20 internal paymentToken;

    // --- Users ---
    address internal admin;
    address internal projectOwner;
    address internal buyer;

    // --- Constants ---
    bytes32 internal constant PROJECT_ID_1 = keccak256("project-1");
    bytes32 internal constant PROJECT_ID_2 = keccak256("project-2");

    function setUp() public {
        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");
        buyer = makeAddr("buyer");

        vm.startPrank(admin);

        // --- Deploy Dependencies ---
        // Correctly deploy ProjectRegistry behind a proxy
        ProjectRegistry registryImpl = new ProjectRegistry();
        projectRegistry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );

        // Correctly deploy DynamicImpactCredit behind a proxy
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        creditToken = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(creditImpl),
                    abi.encodeCall(
                        DynamicImpactCredit.initializeDynamicImpactCredit,
                        (address(projectRegistry), "https://example.com/")
                    )
                )
            )
        );
        creditToken.grantRole(creditToken.DMRV_MANAGER_ROLE(), admin);

        paymentToken = new MockERC20("Payment Token", "PAY", 18);

        // --- Deploy and Initialize Marketplace ---
        marketplace = Marketplace(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new Marketplace()),
                        abi.encodeCall(Marketplace.initialize, (address(creditToken), address(paymentToken)))
                    )
                )
            )
        );
        vm.stopPrank();

        // --- Setup Projects and Mint Credits ---
        vm.startPrank(projectOwner);
        projectRegistry.registerProject(PROJECT_ID_1, "meta_uri_1");
        projectRegistry.registerProject(PROJECT_ID_2, "meta_uri_2");
        vm.stopPrank();

        vm.startPrank(admin);
        projectRegistry.setProjectStatus(PROJECT_ID_1, IProjectRegistry.ProjectStatus.Active);
        projectRegistry.setProjectStatus(PROJECT_ID_2, IProjectRegistry.ProjectStatus.Active);

        creditToken.mintCredits(projectOwner, PROJECT_ID_1, 100e18, "cid1");
        creditToken.mintCredits(projectOwner, PROJECT_ID_2, 200e18, "cid2");
        vm.stopPrank();
    }

    function test_batchList_succeeds_with_valid_data() public {
        // --- Setup ---
        vm.startPrank(projectOwner);
        creditToken.setApprovalForAll(address(marketplace), true);

        // --- Prepare Batch Data ---
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = uint256(PROJECT_ID_1);
        tokenIds[1] = uint256(PROJECT_ID_2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e18;
        amounts[1] = 20e18;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100;
        prices[1] = 200;

        uint256[] memory expiries = new uint256[](2);
        expiries[0] = 1 days;
        expiries[1] = 2 days;

        // --- Action ---
        uint256[] memory listingIds = marketplace.batchList(tokenIds, amounts, prices, expiries);
        vm.stopPrank();

        // --- Assertions ---
        assertEq(listingIds.length, 2, "Should create two listings");

        // 1. Check first listing using the correct getListing function
        Marketplace.Listing memory listing1 = marketplace.getListing(listingIds[0]);
        assertEq(listing1.seller, projectOwner);
        assertEq(listing1.tokenId, tokenIds[0]);
        assertEq(listing1.amount, amounts[0]);
        assertEq(listing1.pricePerUnit, prices[0]);

        // 2. Check second listing using the correct getListing function
        Marketplace.Listing memory listing2 = marketplace.getListing(listingIds[1]);
        assertEq(listing2.seller, projectOwner);
        assertEq(listing2.tokenId, tokenIds[1]);
        assertEq(listing2.amount, amounts[1]);
        assertEq(listing2.pricePerUnit, prices[1]);

        // 3. Check token balances
        assertEq(creditToken.balanceOf(address(marketplace), tokenIds[0]), amounts[0]);
        assertEq(creditToken.balanceOf(address(marketplace), tokenIds[1]), amounts[1]);
    }
}
