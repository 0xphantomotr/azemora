// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./AccountAbstraction.t.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {IPaymaster} from "@account-abstraction/interfaces/IPaymaster.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {UserOperationLib} from "@account-abstraction/core/UserOperationLib.sol";

contract AccountAbstractionFuzzTest is AccountAbstractionTest {
    function setUp() public override {
        super.setUp();
    }

    function test_fuzz_SponsorPaymasterRevertsForUnsponsored(PackedUserOperation calldata op, address randomTarget)
        public
    {
        // We only want to test the sponsorship logic.
        // Assume the fuzzed target is not the one we sponsor, and not the zero address.
        vm.assume(randomTarget != address(projectRegistry) && randomTarget != address(0));

        // Manually construct a valid calldata, overriding the fuzzer's potentially invalid one.
        bytes memory innerCallData = abi.encodeWithSelector(bytes4(0xdeadbeef)); // A simple placeholder call
        bytes memory validCallData =
            abi.encodeWithSelector(AzemoraSmartWallet.execute.selector, randomTarget, 0, innerCallData);

        // To modify the calldata, we need a mutable copy of the struct in memory.
        PackedUserOperation memory mutableOp = op;
        mutableOp.callData = validCallData;

        // Fund the sender so it can pay for the revert if the paymaster rejects.
        entryPoint.depositTo{value: 1 ether}(op.sender);

        vm.prank(address(entryPoint));
        vm.expectRevert("SponsorPaymaster: operation not sponsored");
        sponsorPaymaster.validatePaymasterUserOp(mutableOp, bytes32(0), 1e18);
    }

    function test_fuzz_TokenPaymasterRevertsForLowAllowance(PackedUserOperation calldata op, uint128 allowance)
        public
    {
        vm.assume(allowance < 1e18);

        vm.mockCall(
            address(azemoraToken),
            abi.encodeWithSelector(IERC20.allowance.selector, op.sender, address(tokenPaymaster)),
            abi.encode(allowance)
        );

        vm.prank(address(entryPoint));
        vm.expectRevert("TokenPaymaster: insufficient token allowance");
        tokenPaymaster.validatePaymasterUserOp(op, bytes32(0), 2e18); // Ensure maxCost > allowance
    }

    function test_fuzz_AA_Sponsored(bytes32 projectId, string calldata metadata) public {
        if (bytes(metadata).length > 1000) {
            return; // Keep metadata reasonable
        }
        if (projectId == bytes32(0)) {
            projectId = bytes32("default-fuzz-id");
        }

        sponsorPaymaster.setContractSponsorship(address(projectRegistry), true);

        bytes memory innerCallData =
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId, metadata);

        bytes memory callData =
            abi.encodeWithSelector(AzemoraSmartWallet.execute.selector, address(projectRegistry), 0, innerCallData);

        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSelector(factory.createAccount.selector, owner, 0));

        // CORRECTED: paymasterAndData must be >= 52 bytes with proper format
        bytes memory paymasterAndData = abi.encodePacked(
            address(sponsorPaymaster),
            uint128(5e6), // verificationGasLimit
            uint128(5e6) // postOpGasLimit
        );

        PackedUserOperation memory op = _createAndSignOp(callData, paymasterAndData, initCode, 0);

        uint256 walletBalanceBefore = address(wallet).balance;

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);

        projectRegistry.getProject(projectId);
        assertEq(address(wallet).balance, walletBalanceBefore, "Wallet should NOT have paid for gas");
    }
}
