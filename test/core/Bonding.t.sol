// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/Bonding.sol";
import "../../src/token/AzemoraToken.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BondingTest is Test {
    // --- Contracts ---
    AzemoraToken azeToken;
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    Bonding bonding;

    // --- Actors ---
    address deployer = makeAddr("deployer");
    address bonder = makeAddr("bonder");
    address treasury; // Will be set to a fresh address in setUp

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy AzemoraToken
        AzemoraToken azeTokenImpl = new AzemoraToken();
        azeToken =
            AzemoraToken(address(new ERC1967Proxy(address(azeTokenImpl), abi.encodeCall(AzemoraToken.initialize, ()))));

        // Deploy DynamicImpactCredit (as the bondable asset)
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        DynamicImpactCredit creditImpl = new DynamicImpactCredit(address(registry));
        credit = DynamicImpactCredit(
            address(new ERC1967Proxy(address(creditImpl), abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://"))))
        );

        // Deploy Bonding Contract
        // Using a fresh address for the treasury makes tests cleaner
        treasury = makeAddr("treasury");
        bonding = new Bonding(address(azeToken), treasury);

        // Transfer ownership to the deployer for this test context
        bonding.transferOwnership(deployer);
        vm.stopPrank();

        // --- Setup Actor State ---
        bytes32 projectId = keccak256("Test Project");

        // In this test, we grant the deployer minting rights to set up the scenario.
        // This avoids needing to deploy the full dMRVManager.
        vm.startPrank(bonder); // The bonder owns the project in this test
        registry.registerProject(projectId, "ipfs://project-meta");
        vm.stopPrank();

        vm.startPrank(deployer); // The deployer has the VERIFIER_ROLE and DMRV_MANAGER_ROLE
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), deployer);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        credit.mintCredits(bonder, projectId, 100, "ipfs://some-verification-data");
        vm.stopPrank();
    }

    function test_Bond_Succeeds() public {
        // --- Setup Bond Terms (as DAO/deployer) ---
        bytes32 projectId = keccak256("Test Project");
        uint256 tokenId = uint256(projectId);
        uint256 price = 100e18; // 100 AZE per impact credit
        uint256 vestingPeriod = 7 days;

        vm.prank(deployer);
        bonding.setBondTerm(tokenId, address(credit), price, vestingPeriod, true);

        // --- Bonder executes the bond ---
        uint256 amountToBond = 10;
        uint256 bonderInitialCredits = credit.balanceOf(bonder, tokenId);

        // The bonder must approve the Bonding contract to take their credits
        vm.startPrank(bonder);
        credit.setApprovalForAll(address(bonding), true);

        // Expect the BondCreated event to be emitted
        vm.expectEmit(true, true, true, true);
        emit Bonding.BondCreated(bonder, tokenId, amountToBond, amountToBond * price);

        bonding.bond(tokenId, amountToBond);
        vm.stopPrank();

        // --- Assertions ---

        // 1. Check bonder's credit balance decreased
        assertEq(
            credit.balanceOf(bonder, tokenId), bonderInitialCredits - amountToBond, "Bonder's credits not transferred"
        );

        // 2. Check treasury's credit balance increased
        assertEq(credit.balanceOf(treasury, tokenId), amountToBond, "Treasury did not receive credits");

        // 3. Check user's bond was created correctly
        Bonding.UserBond memory userBond = bonding.getUserBond(bonder, 0);
        assertEq(userBond.amountOwedAZE, amountToBond * price, "AZE owed is incorrect");
        assertEq(userBond.vestingEndsAt, block.timestamp + vestingPeriod, "Vesting period is incorrect");
        assertEq(userBond.claimed, false, "Bond should be marked as unclaimed");
    }

    function test_RevertIf_ClaimBeforeVesting() public {
        // --- Setup: Create a bond ---
        bytes32 projectId = keccak256("Test Project");
        uint256 tokenId = uint256(projectId);
        uint256 price = 100e18;
        uint256 vestingPeriod = 7 days;
        uint256 amountToBond = 10;

        vm.prank(deployer);
        bonding.setBondTerm(tokenId, address(credit), price, vestingPeriod, true);

        vm.startPrank(bonder);
        credit.setApprovalForAll(address(bonding), true);
        bonding.bond(tokenId, amountToBond);
        vm.stopPrank();

        // --- Action: Attempt to claim immediately ---
        vm.prank(bonder);
        vm.expectRevert("Vesting period not over");
        bonding.claim(0);
    }

    function test_Claim_Succeeds_AfterVesting() public {
        // --- Setup: Create a bond and fund the bonding contract ---
        bytes32 projectId = keccak256("Test Project");
        uint256 tokenId = uint256(projectId);
        uint256 price = 100e18;
        uint256 vestingPeriod = 7 days;
        uint256 amountToBond = 10;
        uint256 azeOwed = amountToBond * price;

        vm.startPrank(deployer);
        bonding.setBondTerm(tokenId, address(credit), price, vestingPeriod, true);

        // The DAO/deployer must fund the bonding contract with enough AZE
        azeToken.transfer(address(bonding), azeOwed);
        vm.stopPrank();

        vm.startPrank(bonder);
        credit.setApprovalForAll(address(bonding), true);
        bonding.bond(tokenId, amountToBond);
        vm.stopPrank();

        // --- Action: DAO deactivates the bond term AFTER the user has bonded ---
        // This should NOT affect the user's ability to claim their vested tokens.
        vm.prank(deployer);
        bonding.setBondTerm(tokenId, address(credit), price, vestingPeriod, false);

        // --- Action: Warp time past the vesting period and claim ---
        vm.warp(block.timestamp + vestingPeriod + 1);

        uint256 bonderAzeBalanceBefore = azeToken.balanceOf(bonder);

        vm.prank(bonder);
        bonding.claim(0);

        // --- Assertions ---
        // 1. Check bonder's AZE balance increased
        assertEq(azeToken.balanceOf(bonder), bonderAzeBalanceBefore + azeOwed, "Bonder did not receive AZE");

        // 2. Check bond is marked as claimed
        Bonding.UserBond memory userBond = bonding.getUserBond(bonder, 0);
        assertTrue(userBond.claimed, "Bond should be marked as claimed");
    }

    function test_RevertIf_DoubleClaim() public {
        // First, run the successful claim test to set up the state
        test_Claim_Succeeds_AfterVesting();

        // --- Action: Attempt to claim the same bond again ---
        // The bonder is still the active prank caller from the previous test run.
        vm.prank(bonder);
        vm.expectRevert("Bond already claimed");
        bonding.claim(0);
    }

    function test_RevertIf_BondingToInactiveTerm() public {
        // --- Setup: Create an INACTIVE bond term ---
        bytes32 projectId = keccak256("Test Project");
        uint256 tokenId = uint256(projectId);
        uint256 price = 100e18;
        uint256 vestingPeriod = 7 days;

        vm.prank(deployer);
        bonding.setBondTerm(tokenId, address(credit), price, vestingPeriod, false); // Term is inactive

        // --- Action: Attempt to bond to the inactive term ---
        vm.prank(bonder);
        vm.expectRevert("This bond term is not active");
        bonding.bond(tokenId, 10);
    }
}
