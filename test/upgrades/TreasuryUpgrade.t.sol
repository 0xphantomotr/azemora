// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/governance/Treasury.sol";
import "./TreasuryV2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract TreasuryUpgradeTest is Test {
    // Contracts
    Treasury treasury;
    TreasuryV2 treasuryV2;
    ERC20Mock paymentToken;

    // Users
    address admin = makeAddr("admin");
    address user = makeAddr("user");

    function setUp() public {
        vm.startPrank(admin);

        // Deploy V1 and Proxy
        Treasury treasuryV1Impl = new Treasury();
        bytes memory initData = abi.encodeCall(Treasury.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(treasuryV1Impl), initData);
        treasury = Treasury(payable(address(proxy)));

        vm.stopPrank();

        // Fund the treasury with some ETH and ERC20 tokens
        paymentToken = new ERC20Mock();
        paymentToken.mint(address(treasury), 1000 ether);
        vm.deal(address(treasury), 10 ether);
    }

    function test_upgradeTreasury_preservesFundsAndOwnership() public {
        // --- 1. Pre-Upgrade Assertions ---
        assertEq(treasury.owner(), admin, "Pre-upgrade: owner should be admin");
        assertEq(paymentToken.balanceOf(address(treasury)), 1000 ether, "Pre-upgrade: ERC20 balance is incorrect");
        assertEq(address(treasury).balance, 10 ether, "Pre-upgrade: ETH balance is incorrect");

        // --- 2. Deploy V2 and Upgrade ---
        vm.startPrank(admin);
        TreasuryV2 treasuryV2Impl = new TreasuryV2();
        // Use `upgradeToAndCall` to call the new V2 initializer
        bytes memory upgradeCallData = abi.encodeCall(TreasuryV2.initializeV2, ());
        // Cast to UUPSUpgradeable to access upgradeToAndCall
        UUPSUpgradeable(payable(address(treasury))).upgradeToAndCall(address(treasuryV2Impl), upgradeCallData);
        vm.stopPrank();

        // --- 3. Post-Upgrade Assertions ---
        treasuryV2 = TreasuryV2(payable(address(treasury)));

        // Check that state (owner and funds) is preserved
        assertEq(treasuryV2.owner(), admin, "Post-upgrade: owner should be preserved");
        assertEq(
            paymentToken.balanceOf(address(treasuryV2)), 1000 ether, "Post-upgrade: ERC20 balance should be preserved"
        );
        assertEq(address(treasuryV2).balance, 10 ether, "Post-upgrade: ETH balance should be preserved");

        // Check that old functions still work
        vm.prank(admin);
        treasuryV2.withdrawETH(user, 1 ether);
        assertEq(address(treasuryV2).balance, 9 ether, "Post-upgrade: withdrawETH should still work");
    }
}
