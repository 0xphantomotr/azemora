// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol"; // Import console for logging

import {EntryPoint} from "@account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AzemoraSmartWallet} from "../../src/account-abstraction/wallet/AzemoraSmartWallet.sol";
import {AzemoraSmartWalletFactory} from "../../src/account-abstraction/wallet/AzemoraSmartWalletFactory.sol";
import {TokenPaymaster} from "../../src/account-abstraction/paymaster/TokenPaymaster.sol";
import {SponsorPaymaster} from "../../src/account-abstraction/paymaster/SponsorPaymaster.sol";
import {MockPriceOracle} from "../../src/account-abstraction/core/MockPriceOracle.sol";
import {AzemoraToken} from "../../src/token/AzemoraToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {UserOperationLib} from "@account-abstraction/core/UserOperationLib.sol";

contract AccountAbstractionTest is Test {
    EntryPoint internal entryPoint;
    AzemoraSmartWalletFactory internal factory;
    TokenPaymaster internal tokenPaymaster;
    SponsorPaymaster internal sponsorPaymaster;
    AzemoraToken internal azemoraToken;
    MockPriceOracle internal mockOracle;
    ProjectRegistry internal projectRegistry;
    AzemoraSmartWallet internal wallet;

    // Create a private key for the owner to enable signing.
    uint256 internal ownerPrivateKey = 0x123456;
    address internal owner;
    address payable internal beneficiary;

    function setUp() public virtual {
        console.log("--- Starting Test Setup ---");

        // Derive the owner address from the private key.
        owner = vm.addr(ownerPrivateKey);

        // Deploy all contracts.
        entryPoint = new EntryPoint();
        console.log("[1] EntryPoint deployed at:", address(entryPoint));

        // The factory now needs the EntryPoint address at construction time.
        factory = new AzemoraSmartWalletFactory(entryPoint);
        console.log("[2] Factory deployed at:", address(factory));

        ProjectRegistry registryImplementation = new ProjectRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImplementation), abi.encodeWithSelector(ProjectRegistry.initialize.selector)
        );
        projectRegistry = ProjectRegistry(address(registryProxy));
        console.log("[2a] ProjectRegistry DEPLOYED. Initializing...");

        AzemoraToken tokenImplementation = new AzemoraToken();
        ERC1967Proxy tokenProxy =
            new ERC1967Proxy(address(tokenImplementation), abi.encodeWithSelector(AzemoraToken.initialize.selector));
        azemoraToken = AzemoraToken(address(tokenProxy));
        console.log("[4] AzemoraToken deployed and initialized");

        mockOracle = new MockPriceOracle(1 ether);
        console.log("[5] MockOracle deployed");

        tokenPaymaster =
            new TokenPaymaster(IEntryPoint(address(entryPoint)), address(azemoraToken), address(mockOracle));
        console.log("[6] TokenPaymaster deployed");

        sponsorPaymaster = new SponsorPaymaster(IEntryPoint(address(entryPoint)));
        console.log("[7] SponsorPaymaster deployed");

        tokenPaymaster.transferOwnership(address(this));
        sponsorPaymaster.transferOwnership(address(this));

        vm.deal(address(tokenPaymaster), 1 ether);
        tokenPaymaster.addStake{value: 1 ether}(1);
        console.log("[8] TokenPaymaster funded and staked");

        vm.deal(address(sponsorPaymaster), 1 ether);
        sponsorPaymaster.addStake{value: 1 ether}(1);
        console.log("[9] SponsorPaymaster funded and staked");

        // After adding stake, deposit ETH for gas
        sponsorPaymaster.deposit{value: 1 ether}();
        console.log("[9a] SponsorPaymaster deposit added");

        tokenPaymaster.deposit{value: 1 ether}();
        console.log("[9b] TokenPaymaster deposit added");

        // Correctly get the counterfactual address using the new getAddress signature.
        address walletAddress = factory.getAddress(owner, 0);

        // We just store the wallet's address. It will be created on the first UserOp via initCode.
        wallet = AzemoraSmartWallet(payable(walletAddress));

        beneficiary = payable(vm.addr(0xbeef));

        vm.deal(address(wallet), 10 ether);
        vm.deal(beneficiary, 10 ether);

        // The wallet needs a deposit in the EntryPoint to be able to pay for its own gas (for UserPaid ops).
        entryPoint.depositTo{value: 1 ether}(address(wallet));
        assertEq(entryPoint.balanceOf(address(wallet)), 1 ether, "Wallet should have a deposit in EntryPoint");

        console.log("--- Setup Complete ---");
    }

    function _createAndSignOp(
        bytes memory callData,
        bytes memory paymasterAndData,
        bytes memory initCode,
        uint256 nonce
    ) internal view returns (PackedUserOperation memory) {
        // If paymasterAndData is not empty but less than PAYMASTER_DATA_OFFSET (52 bytes),
        // format it correctly by adding verification and postOp gas limits
        if (paymasterAndData.length > 0 && paymasterAndData.length < UserOperationLib.PAYMASTER_DATA_OFFSET) {
            // Extract paymaster address (first 20 bytes)
            address paymaster = address(0);
            if (paymasterAndData.length >= 20) {
                // Use assembly to extract the first 20 bytes
                assembly {
                    paymaster := mload(add(paymasterAndData, 20))
                    // Shift right to get the correct 160 bits (20 bytes)
                    paymaster := shr(96, paymaster)
                }
            }

            // Create properly formatted paymasterAndData:
            // paymaster address (20 bytes) +
            // verification gas limit (16 bytes) +
            // postOp gas limit (16 bytes)
            paymasterAndData = abi.encodePacked(
                paymaster,
                uint128(5e6), // verificationGasLimit
                uint128(5e6) // postOpGasLimit
            );
        }

        PackedUserOperation memory op = PackedUserOperation({
            sender: address(wallet),
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, opHash);
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }

    // Test 1: Basic user-paid operation
    function test_AA_UserPaid() public {
        bytes32 projectId = bytes32("test-project-user-paid");

        // Use a different salt to ensure a fresh wallet for this test, avoiding state clash with other tests.
        uint256 userPaidSalt = 1;
        address userPaidWalletAddr = factory.getAddress(owner, userPaidSalt);
        entryPoint.depositTo{value: 1 ether}(userPaidWalletAddr);

        bytes memory initCode = abi.encodePacked(
            address(factory), abi.encodeWithSelector(factory.createAccount.selector, owner, userPaidSalt)
        );

        bytes memory callData = abi.encodeWithSelector(
            AzemoraSmartWallet.execute.selector,
            address(projectRegistry),
            0,
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId, "http://meta.uri")
        );

        // We can't use the `_createAndSignOp` helper here because we are using a different wallet address.
        PackedUserOperation memory op = PackedUserOperation({
            sender: userPaidWalletAddr,
            nonce: 0,
            initCode: initCode,
            callData: callData,
            accountGasLimits: bytes32(abi.encodePacked(uint128(5e6), uint128(5e6))),
            preVerificationGas: 10e6,
            gasFees: bytes32(abi.encodePacked(uint128(1e9), uint128(1e9))),
            paymasterAndData: "",
            signature: ""
        });
        bytes32 opHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, opHash);
        op.signature = abi.encodePacked(r, s, v);

        uint256 depositBefore = entryPoint.balanceOf(userPaidWalletAddr);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);

        projectRegistry.getProject(projectId);

        uint256 depositAfter = entryPoint.balanceOf(userPaidWalletAddr);
        assertTrue(depositAfter < depositBefore, "Wallet's deposit in EntryPoint should have been used for gas");
    }

    // Test 2: Sponsored operation
    function test_AA_Sponsored() public {
        bytes32 projectId = bytes32("sponsored-project");
        sponsorPaymaster.setActionSponsorship(address(projectRegistry), projectRegistry.registerProject.selector, true);

        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSelector(factory.createAccount.selector, owner, 0));

        bytes memory callData = abi.encodeWithSelector(
            AzemoraSmartWallet.execute.selector,
            address(projectRegistry),
            0,
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId, "http://meta.uri")
        );

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

    function test_Fail_AA_Sponsored_SecondTime() public {
        bytes32 projectId1 = bytes32("sponsored-project-1");
        bytes32 projectId2 = bytes32("sponsored-project-2");
        sponsorPaymaster.setActionSponsorship(address(projectRegistry), projectRegistry.registerProject.selector, true);

        // --- First Call (Successful) ---
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSelector(factory.createAccount.selector, owner, 0));
        bytes memory callData1 = abi.encodeWithSelector(
            AzemoraSmartWallet.execute.selector,
            address(projectRegistry),
            0,
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId1, "http://meta1.uri")
        );
        bytes memory paymasterAndData = abi.encodePacked(
            address(sponsorPaymaster),
            uint128(5e6), // verificationGasLimit
            uint128(5e6) // postOpGasLimit
        );
        PackedUserOperation memory op1 = _createAndSignOp(callData1, paymasterAndData, initCode, 0);
        PackedUserOperation[] memory ops1 = new PackedUserOperation[](1);
        ops1[0] = op1;
        entryPoint.handleOps(ops1, beneficiary);
        projectRegistry.getProject(projectId1); // Verify it worked

        // --- Second Call (Should Fail) ---
        bytes memory callData2 = abi.encodeWithSelector(
            AzemoraSmartWallet.execute.selector,
            address(projectRegistry),
            0,
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId2, "http://meta2.uri")
        );
        // Use the same paymaster data, but a new nonce (1)
        PackedUserOperation memory op2 = _createAndSignOp(callData2, paymasterAndData, "", 1);
        PackedUserOperation[] memory ops2 = new PackedUserOperation[](1);
        ops2[0] = op2;

        // The EntryPoint reverts with `FailedOpWithRevert`, wrapping the paymaster's original error.
        // We must match this specific error signature.
        bytes memory expectedRevertData = abi.encodeWithSelector(
            bytes4(keccak256(bytes("Error(string)"))), "SponsorPaymaster: action already sponsored for this user"
        );
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOpWithRevert.selector, 0, "AA33 reverted", expectedRevertData)
        );
        entryPoint.handleOps(ops2, beneficiary);
    }

    // Test 3: Token-paid operation
    function test_AA_TokenPaid() public {
        bytes32 projectId = bytes32("token-paid-project");
        uint256 initialTokenBalance = 1000 * 1e18;
        azemoraToken.transfer(address(wallet), initialTokenBalance);

        // Set a 10% fee for the paymaster service
        uint256 feePercentage = 10;
        tokenPaymaster.setFeePercentage(feePercentage);

        // --- Scope for Approval Step ---
        {
            bytes memory initCode =
                abi.encodePacked(address(factory), abi.encodeWithSelector(factory.createAccount.selector, owner, 0));
            bytes memory approveCallData = abi.encodeWithSelector(
                AzemoraSmartWallet.execute.selector,
                address(azemoraToken),
                0,
                abi.encodeWithSelector(IERC20.approve.selector, address(tokenPaymaster), type(uint256).max)
            );
            PackedUserOperation memory approveOp = _createAndSignOp(approveCallData, "", initCode, 0);
            PackedUserOperation[] memory approveOps = new PackedUserOperation[](1);
            approveOps[0] = approveOp;
            entryPoint.handleOps(approveOps, beneficiary);

            assertEq(
                azemoraToken.allowance(address(wallet), address(tokenPaymaster)),
                type(uint256).max,
                "Allowance should be set"
            );
        }
        // Variables from the scope above are now cleared from the stack.

        // --- Main Operation Step ---
        bytes memory registerCallData = abi.encodeWithSelector(
            AzemoraSmartWallet.execute.selector,
            address(projectRegistry),
            0,
            abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId, "http://meta.uri")
        );
        bytes memory tokenPaymasterAndData = abi.encodePacked(
            address(tokenPaymaster),
            uint128(5e6), // verificationGasLimit
            uint128(5e6) // postOpGasLimit
        );
        PackedUserOperation memory registerOp = _createAndSignOp(registerCallData, tokenPaymasterAndData, "", 1);

        PackedUserOperation[] memory registerOps = new PackedUserOperation[](1);
        registerOps[0] = registerOp;

        // We expect the TokenPaymaster to emit the TokensCharged event.
        // We will check that the first topic (the user's address) is correct.
        // We will NOT check the data payload (actualGasCost, tokenCost) as it is non-deterministic.
        vm.expectEmit(true, false, false, false);
        emit TokenPaymaster.TokensCharged(address(wallet), 0, 0); // We check topic1 (user) but ignore the data (costs).

        entryPoint.handleOps(registerOps, beneficiary);

        // Final verification that the project was registered.
        projectRegistry.getProject(projectId);
    }

    function test_AA_ExecuteBatch() public {
        bytes32 projectId1 = bytes32("batch-project-1");
        bytes32 projectId2 = bytes32("batch-project-2");
        uint256 batchSalt = 2;
        address batchWalletAddr = factory.getAddress(owner, batchSalt);

        // --- Scope for Arrange & Act ---
        {
            entryPoint.depositTo{value: 1 ether}(batchWalletAddr);

            bytes memory initCode = abi.encodePacked(
                address(factory), abi.encodeWithSelector(factory.createAccount.selector, owner, batchSalt)
            );

            address[] memory dests = new address[](2);
            dests[0] = address(projectRegistry);
            dests[1] = address(projectRegistry);

            bytes[] memory funcs = new bytes[](2);
            funcs[0] = abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId1, "http://batch1.uri");
            funcs[1] = abi.encodeWithSelector(ProjectRegistry.registerProject.selector, projectId2, "http://batch2.uri");

            bytes memory batchCallData = abi.encodeWithSelector(AzemoraSmartWallet.executeBatch.selector, dests, funcs);

            PackedUserOperation memory op = PackedUserOperation({
                sender: batchWalletAddr,
                nonce: 0,
                initCode: initCode,
                callData: batchCallData,
                accountGasLimits: bytes32(abi.encodePacked(uint128(5e6), uint128(5e6))),
                preVerificationGas: 10e6,
                gasFees: bytes32(abi.encodePacked(uint128(1e9), uint128(1e9))),
                paymasterAndData: "",
                signature: ""
            });
            bytes32 opHash = entryPoint.getUserOpHash(op);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, opHash);
            op.signature = abi.encodePacked(r, s, v);

            PackedUserOperation[] memory ops = new PackedUserOperation[](1);
            ops[0] = op;
            entryPoint.handleOps(ops, beneficiary);
        }

        // --- Scope for Assert ---
        // Verify that both projects were registered successfully.
        ProjectRegistry.Project memory project1 = projectRegistry.getProject(projectId1);
        ProjectRegistry.Project memory project2 = projectRegistry.getProject(projectId2);
        assertEq(project1.owner, batchWalletAddr, "Project 1 should be registered to the wallet");
        assertEq(project2.owner, batchWalletAddr, "Project 2 should be registered to the wallet");
    }

    function test_Fail_SponsorPaymaster_InvalidCalldata_NotExecute() public {
        // This test ensures the paymaster rejects a UserOp if its calldata
        // does not target the wallet's `execute` or `executeBatch` function.

        // This is a dummy calldata that does NOT start with the `execute` selector.
        bytes memory invalidCallData = abi.encodeWithSelector(bytes4(0xdeadbeef));

        PackedUserOperation memory op = _createAndSignOp(invalidCallData, abi.encode(address(sponsorPaymaster)), "", 0);

        // We call the paymaster's validation function directly, as the EntryPoint
        // would not even let us get this far with invalid calldata.
        vm.prank(address(entryPoint));
        vm.expectRevert("SponsorPaymaster: sponsored action must be via execute()");
        sponsorPaymaster.validatePaymasterUserOp(op, bytes32(0), 1e18);
    }
}
