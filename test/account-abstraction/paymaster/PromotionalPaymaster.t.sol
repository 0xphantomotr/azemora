// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IPaymaster} from "@account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "@account-abstraction/core/EntryPoint.sol";
import {SimpleAccountFactory} from "@account-abstraction/accounts/SimpleAccountFactory.sol";
import {SimpleAccount} from "@account-abstraction/accounts/SimpleAccount.sol";
import {BaseAccount} from "@account-abstraction/core/BaseAccount.sol";
import {PromotionalPaymaster} from "src/account-abstraction/paymaster/PromotionalPaymaster.sol";

contract PromotionalPaymasterTest is Test {
    EntryPoint public entryPoint;
    PromotionalPaymaster public paymaster;
    SimpleAccountFactory public accountFactory;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    SimpleAccount public userAccount;

    function setUp() public {
        entryPoint = new EntryPoint();
        paymaster = new PromotionalPaymaster(IEntryPoint(address(entryPoint)));
        accountFactory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));

        // The test contract is the initial owner. Immediately transfer ownership to `owner`.
        paymaster.transferOwnership(owner);

        // Fund the new owner, then have them stake and deposit for the paymaster.
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        paymaster.addStake{value: 1 ether}(1);
        paymaster.deposit{value: 9 ether}();
        vm.stopPrank();

        // Create a smart contract wallet for our test user
        // We don't deploy the account directly. Instead, we calculate its future address.
        address accountAddress = accountFactory.getAddress(user, 0);
        userAccount = SimpleAccount(payable(accountAddress));
        vm.deal(accountAddress, 1 ether); // Fund the counterfactual address
    }

    function test_owner_can_set_and_deactivate_promotion() public {
        uint256 promotionId = 1;
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + 1 days;
        uint256 userTxLimit = 5;
        uint256 totalTxLimit = 1000;

        vm.prank(owner);
        paymaster.setPromotion(promotionId, startTime, endTime, userTxLimit, totalTxLimit);

        PromotionalPaymaster.Promotion memory promo = paymaster.getPromotion();
        assertEq(promo.id, promotionId);
        assertEq(promo.userTxLimit, userTxLimit);
        assertEq(promo.totalTxLimit, totalTxLimit);

        vm.prank(owner);
        paymaster.deactivatePromotion();
        promo = paymaster.getPromotion();
        assertEq(promo.id, 0);
    }

    function test_revert_nonOwner_cannot_set_promotion() public {
        vm.expectRevert("not owner");
        paymaster.setPromotion(1, block.timestamp, block.timestamp + 1 days, 5, 1000);
    }

    function test_sponsorship_success() public {
        // Setup promotion
        vm.prank(owner);
        paymaster.setPromotion(1, block.timestamp, block.timestamp + 1 days, 5, 1000);

        // Craft UserOp
        PackedUserOperation memory userOp = _getPackedUserOp();

        // Validate
        vm.prank(address(entryPoint));
        (bytes memory context,) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
        (address userAddress, uint256 promotionId) = abi.decode(context, (address, uint256));
        assertEq(userAddress, address(userAccount));
        assertEq(promotionId, 1);

        // postOp
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0, 0);

        // Assert state change
        assertEq(paymaster.userPromotionTxCount(1, address(userAccount)), 1);
        assertEq(paymaster.getPromotion().sponsoredTxCount, 1);
    }

    function test_revert_noActivePromotion() public {
        PackedUserOperation memory userOp = _getPackedUserOp();

        vm.prank(address(entryPoint));
        vm.expectRevert("PromotionalPaymaster: no active promotion");
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_revert_userTxLimitReached() public {
        vm.prank(owner);
        paymaster.setPromotion(1, block.timestamp, block.timestamp + 1 days, 2, 1000); // User limit of 2

        PackedUserOperation memory userOp = _getPackedUserOp();

        // Use up the limit
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(address(entryPoint));
            (bytes memory context,) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
            vm.prank(address(entryPoint));
            paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0, 0);
        }

        assertEq(paymaster.userPromotionTxCount(1, address(userAccount)), 2);

        // Assert next validation fails
        vm.prank(address(entryPoint));
        vm.expectRevert("PromotionalPaymaster: user transaction limit reached for this promotion");
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_revert_totalTxLimitReached() public {
        vm.prank(owner);
        paymaster.setPromotion(1, block.timestamp, block.timestamp + 1 days, 10, 2); // Total limit of 2

        PackedUserOperation memory userOp = _getPackedUserOp();

        // Use up the limit with two different users
        address anotherUser = makeAddr("anotherUser");
        address anotherUserAccountAddress = accountFactory.getAddress(anotherUser, 0);
        PackedUserOperation memory anotherUserOp = userOp;
        anotherUserOp.sender = anotherUserAccountAddress;

        // First user
        vm.prank(address(entryPoint));
        (bytes memory context1,) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context1, 0, 0);

        // Second user
        vm.prank(address(entryPoint));
        (bytes memory context2,) = paymaster.validatePaymasterUserOp(anotherUserOp, bytes32(0), 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context2, 0, 0);

        assertEq(paymaster.getPromotion().sponsoredTxCount, 2);

        // Assert next validation fails for a third user
        address thirdUser = makeAddr("thirdUser");
        address thirdUserAccountAddress = accountFactory.getAddress(thirdUser, 0);
        PackedUserOperation memory thirdUserOp = userOp;
        thirdUserOp.sender = thirdUserAccountAddress;

        vm.prank(address(entryPoint));
        vm.expectRevert("PromotionalPaymaster: promotion total budget reached");
        paymaster.validatePaymasterUserOp(thirdUserOp, bytes32(0), 0);
    }

    function test_revert_promotionNotStarted() public {
        // Set promotion to start in the future
        vm.prank(owner);
        paymaster.setPromotion(1, block.timestamp + 1 hours, block.timestamp + 2 hours, 5, 100);

        PackedUserOperation memory userOp = _getPackedUserOp();

        vm.prank(address(entryPoint));
        vm.expectRevert("PromotionalPaymaster: promotion not currently active");
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_revert_promotionEnded() public {
        // Warp time forward to ensure block.timestamp is not near zero
        vm.warp(2 hours);

        // Set promotion that has already ended
        vm.prank(owner);
        paymaster.setPromotion(1, block.timestamp - 2 hours, block.timestamp - 1 hours, 5, 100);

        PackedUserOperation memory userOp = _getPackedUserOp();

        vm.prank(address(entryPoint));
        vm.expectRevert("PromotionalPaymaster: promotion not currently active");
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_revert_setPromotion_invalidTimes() public {
        vm.prank(owner);
        vm.expectRevert("start time must be before end time");
        paymaster.setPromotion(1, block.timestamp, block.timestamp - 1, 5, 100); // end time < start time
    }

    function test_postOp_failedTx_noStateChange() public {
        vm.prank(owner);
        paymaster.setPromotion(1, block.timestamp, block.timestamp + 1 days, 5, 1000);

        PackedUserOperation memory userOp = _getPackedUserOp();

        vm.prank(address(entryPoint));
        (bytes memory context,) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);

        // Call postOp with opReverted for a failed tx
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opReverted, context, 0, 0);

        // Assert state did NOT change
        assertEq(paymaster.userPromotionTxCount(1, address(userAccount)), 0);
        assertEq(paymaster.getPromotion().sponsoredTxCount, 0);
    }

    // --- Helper Functions ---

    function _getPackedUserOp() internal view returns (PackedUserOperation memory) {
        // This is a simplified UserOp for testing validation.
        // It doesn't need a valid signature for this test.
        bytes memory callData = abi.encodeWithSelector(BaseAccount.execute.selector, address(0xdead), 0, "");

        return PackedUserOperation({
            sender: address(userAccount),
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(0),
            preVerificationGas: 100000,
            gasFees: bytes32(0),
            paymasterAndData: abi.encode(address(paymaster), ""),
            signature: ""
        });
    }
}
