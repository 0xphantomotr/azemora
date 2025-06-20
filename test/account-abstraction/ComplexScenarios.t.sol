// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./AccountAbstraction.t.sol";
import {AzemoraSocialRecoveryWallet} from "../../src/account-abstraction/wallet/AzemoraSocialRecoveryWallet.sol";
import {AzemoraSocialRecoveryWalletFactory} from
    "../../src/account-abstraction/wallet/AzemoraSocialRecoveryWalletFactory.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ComplexScenariosTest is AccountAbstractionTest {
    // --- Shared State for Scenario Tests ---
    AzemoraSocialRecoveryWallet internal recoveryWallet;
    uint256 internal ownerKey = 0xbeef;
    uint256 internal newOwnerKey = 0xcafe;
    address internal ownerAddr;
    address internal newOwnerAddr;
    address internal walletAddr;

    function setUp() public override {
        super.setUp(); // Sets up the base paymasters and registry

        // --- Deploy a Social Recovery Wallet for these tests ---
        ownerAddr = vm.addr(ownerKey);
        newOwnerAddr = vm.addr(newOwnerKey);

        address[] memory guardians = new address[](3);
        guardians[0] = makeAddr("guardian1");
        guardians[1] = makeAddr("guardian2");
        guardians[2] = makeAddr("guardian3");

        AzemoraSocialRecoveryWalletFactory recoveryFactory = new AzemoraSocialRecoveryWalletFactory(entryPoint);
        walletAddr = recoveryFactory.createAccount(ownerAddr, guardians, 2, 0);
        recoveryWallet = AzemoraSocialRecoveryWallet(payable(walletAddr));

        // Fund wallet for all stages
        azemoraToken.transfer(walletAddr, 1000 * 1e18);
        vm.deal(walletAddr, 1 ether);
        entryPoint.depositTo{value: 1 ether}(walletAddr);
    }

    // --- Stage 1: Sponsored Action ---
    function test_Scenario_Stage1_Sponsored() public {
        bytes32 projectId = bytes32("sponsored-lifecycle-project");
        sponsorPaymaster.setActionSponsorship(address(projectRegistry), projectRegistry.registerProject.selector, true);

        bytes memory callData = abi.encodeWithSelector(
            recoveryWallet.execute.selector,
            address(projectRegistry),
            0,
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId, "http://uri.1")
        );
        bytes memory pmData = abi.encodePacked(address(sponsorPaymaster), uint128(5e6), uint128(5e6));

        PackedUserOperation memory op = _signOp(ownerKey, walletAddr, 0, "", callData, pmData);
        _handleOp(op);

        ProjectRegistry.Project memory p = projectRegistry.getProject(projectId);
        assertEq(p.owner, walletAddr, "Stage 1: Sponsored project not registered");
    }

    // --- Stage 2: Token-Paid Action ---
    function test_Scenario_Stage2_TokenPaid() public {
        // We assume Stage 1 happened, so wallet exists and nonce is 1
        bytes32 projectId = bytes32("tokenpaid-lifecycle-project");

        // First, approve the paymaster (nonce 0, as this test runs independently)
        bytes memory approveCall = abi.encodeWithSelector(
            recoveryWallet.execute.selector,
            address(azemoraToken),
            0,
            abi.encodeWithSelector(IERC20.approve.selector, address(tokenPaymaster), type(uint256).max)
        );
        PackedUserOperation memory approveOp = _signOp(ownerKey, walletAddr, 0, "", approveCall, "");
        _handleOp(approveOp);

        // Now, perform the token-paid action (nonce 1)
        bytes memory callData = abi.encodeWithSelector(
            recoveryWallet.execute.selector,
            address(projectRegistry),
            0,
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId, "http://uri.2")
        );
        bytes memory pmData = abi.encodePacked(address(tokenPaymaster), uint128(5e6), uint128(5e6));

        uint256 tokenBalanceBefore = azemoraToken.balanceOf(walletAddr);
        PackedUserOperation memory op = _signOp(ownerKey, walletAddr, 1, "", callData, pmData);
        _handleOp(op);

        ProjectRegistry.Project memory p = projectRegistry.getProject(projectId);
        assertEq(p.owner, walletAddr, "Stage 2: Token-paid project not registered");
        assertTrue(azemoraToken.balanceOf(walletAddr) < tokenBalanceBefore, "Stage 2: Token balance did not decrease");
    }

    // --- Stage 3 & 4: Recovery and New Owner Action ---
    function test_Scenario_Stage3_RecoveryAndNewOwnerPaidAction() public {
        // --- Stage 3: Social Recovery ---
        address[] memory guardians = recoveryWallet.getGuardians();
        vm.prank(guardians[0]);
        recoveryWallet.proposeNewOwner(newOwnerAddr);
        vm.prank(guardians[1]);
        recoveryWallet.supportRecovery();

        vm.warp(block.timestamp + recoveryWallet.RECOVERY_TIMELOCK() + 1);

        vm.prank(makeAddr("executor"));
        recoveryWallet.executeRecovery();
        assertEq(recoveryWallet.owner(), newOwnerAddr, "Stage 3: Recovery failed, owner not changed");

        // --- Stage 4: New Owner Action (User-Paid) ---
        bytes32 newUserProjectId = bytes32("new-owner-project");
        bytes memory callData = abi.encodeWithSelector(
            recoveryWallet.execute.selector,
            address(projectRegistry),
            0,
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, newUserProjectId, "http://uri.3")
        );

        uint256 depositBefore = entryPoint.balanceOf(walletAddr);
        // The new owner signs with nonce 0, as the wallet's nonce is per-owner in this simple wallet design.
        // A real advanced wallet might have a single nonce.
        // Let's assume the new owner starts with nonce 0 for their own operations.
        // The wallet's `validateUserOp` doesn't check nonce; the EntryPoint does.
        // And the EntryPoint's nonce is for the wallet address, so this should be nonce 0.
        // Let's find the current nonce for the wallet from the EntryPoint.
        uint256 currentNonce = entryPoint.getNonce(walletAddr, 0);
        PackedUserOperation memory op = _signOp(newOwnerKey, walletAddr, currentNonce, "", callData, "");
        _handleOp(op);

        ProjectRegistry.Project memory p = projectRegistry.getProject(newUserProjectId);
        assertEq(p.owner, walletAddr, "Stage 4: New owner project not registered");
        assertTrue(entryPoint.balanceOf(walletAddr) < depositBefore, "Stage 4: Deposit was not used for gas");
    }

    // --- Helper functions for this test ---

    function _signOp(
        uint256 privateKey,
        address _walletAddr,
        uint256 nonce,
        bytes memory initCode,
        bytes memory callData,
        bytes memory paymasterAndData
    ) internal view returns (PackedUserOperation memory) {
        PackedUserOperation memory op = PackedUserOperation({
            sender: _walletAddr,
            nonce: nonce,
            initCode: initCode,
            callData: callData,
            accountGasLimits: bytes32(abi.encodePacked(uint128(5e6), uint128(5e6))),
            preVerificationGas: 10e6,
            gasFees: bytes32(abi.encodePacked(uint128(1e9), uint128(1e9))),
            paymasterAndData: paymasterAndData,
            signature: ""
        });

        bytes32 opHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, opHash);
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }

    function _handleOp(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }
}
