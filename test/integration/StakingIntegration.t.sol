// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/staking/StakingRewards.sol";
import "../../src/token/AzemoraToken.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import {MethodologyRegistry} from "../../src/core/MethodologyRegistry.sol";

contract StakingIntegrationTest is Test {
    // Contracts
    Marketplace marketplace;
    StakingRewards stakingRewards;
    AzemoraToken azemoraToken;
    DynamicImpactCredit credit;
    ProjectRegistry registry;
    DMRVManager dmrvManager;
    MethodologyRegistry methodologyRegistry;

    // Actors
    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address staker = makeAddr("staker");

    function setUp() public {
        vm.startPrank(admin);

        // --- Deploy Tokens ---
        AzemoraToken tokenImpl = new AzemoraToken();
        azemoraToken =
            AzemoraToken(address(new ERC1967Proxy(address(tokenImpl), abi.encodeCall(AzemoraToken.initialize, ()))));

        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );

        MethodologyRegistry methodologyRegistryImpl = new MethodologyRegistry();
        methodologyRegistry = MethodologyRegistry(
            address(
                new ERC1967Proxy(
                    address(methodologyRegistryImpl), abi.encodeCall(MethodologyRegistry.initialize, (admin))
                )
            )
        );

        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(creditImpl),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "uri"))
                )
            )
        );

        DMRVManager dmrvManagerImpl = new DMRVManager();
        dmrvManager = DMRVManager(
            address(
                new ERC1967Proxy(
                    address(dmrvManagerImpl),
                    abi.encodeCall(
                        DMRVManager.initializeDMRVManager,
                        (address(registry), address(credit), address(methodologyRegistry))
                    )
                )
            )
        );

        // --- Deploy Staking & Marketplace ---
        stakingRewards = new StakingRewards(address(azemoraToken));

        Marketplace marketplaceImpl = new Marketplace();
        marketplace = Marketplace(
            address(
                new ERC1967Proxy(
                    address(marketplaceImpl),
                    abi.encodeCall(Marketplace.initialize, (address(credit), address(azemoraToken)))
                )
            )
        );

        // --- Configure Connections ---
        marketplace.setProtocolFeeBps(1000); // 10% fee for easy math
        marketplace.setTreasury(address(stakingRewards)); // <<< CRITICAL: Fees go to staking contract

        // Grant Roles for Minting and Ownership Transfer
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dmrvManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), admin);
        registry.grantRole(registry.VERIFIER_ROLE(), admin);
        dmrvManager.grantRole(dmrvManager.DEFAULT_ADMIN_ROLE(), admin);

        // --- Distribute Assets ---
        azemoraToken.transfer(buyer, 1000 ether);
        azemoraToken.transfer(staker, 1000 ether);

        // Mint credits properly through the dMRV flow
        bytes32 projectId = keccak256("Test Project For Staking");
        registry.registerProject(projectId, "ipfs://");
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
        // Admin (as oracle) fulfills, minting credits to Admin (as project owner)
        dmrvManager.adminSubmitVerification(projectId, 100, "", false);

        // Explicitly transfer the newly minted credits from Admin to the designated Seller
        credit.safeTransferFrom(admin, seller, uint256(projectId), 100, "");

        vm.stopPrank();
    }

    function test_Integration_MarketplaceFeeToStakingRewards() public {
        // --- 1. Staker stakes their tokens ---
        uint256 stakerInitialBalance = azemoraToken.balanceOf(staker);
        vm.startPrank(staker);
        azemoraToken.approve(address(stakingRewards), 1000 ether);
        stakingRewards.stake(1000 ether);
        vm.stopPrank();

        // --- 2. Seller lists an item ---
        bytes32 projectId = keccak256("Test Project For Staking");
        uint256 tokenId = uint256(projectId);
        uint256 listAmount = 10;
        uint256 pricePerUnit = 100 ether;
        uint256 listingId; // Declare the listingId variable

        vm.startPrank(seller);
        credit.setApprovalForAll(address(marketplace), true);
        listingId = marketplace.list(tokenId, listAmount, pricePerUnit, 1 days); // Capture the returned ID
        vm.stopPrank();

        // --- 3. Buyer purchases the item ---
        uint256 buyAmount = 1;
        uint256 totalPrice = buyAmount * pricePerUnit;
        vm.startPrank(buyer);
        azemoraToken.approve(address(marketplace), totalPrice);
        marketplace.buy(listingId, buyAmount); // Use the captured ID
        vm.stopPrank();

        // --- 4. Verify fee distribution ---
        uint256 fee = (totalPrice * 1000) / 10000;
        assertEq(
            azemoraToken.balanceOf(address(stakingRewards)), 1000 ether + fee, "Staking contract should receive fees"
        );

        // --- 5. Staker claims rewards ---
        // To make rewards claimable, the owner notifies the contract of the new reward amount.
        // We set the duration to 1000 seconds.
        vm.prank(admin);
        stakingRewards.notifyRewardAmount(fee, 1000);

        // Advance time to allow rewards to accrue
        vm.warp(block.timestamp + 1000);

        vm.prank(staker);
        stakingRewards.claimReward();

        // Staker's final balance should be their initial balance + the fee they earned
        uint256 stakerFinalBalance = azemoraToken.balanceOf(staker);
        assertApproxEqAbs(
            stakerFinalBalance, stakerInitialBalance - 1000 ether + fee, 1, "Staker should have earned the fee"
        );
    }
}
