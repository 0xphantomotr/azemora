// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";
import {Treasury} from "../../src/governance/Treasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ProposeScript
 * @dev A script to create a governance proposal to withdraw marketplace fees.
 */
contract ProposeScript is Script {
    function run() external {
        // --- Load Environment Variables ---
        // Governance contracts
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address treasuryAddress = vm.envAddress("TREASURY_ADDRESS");

        // The token that represents the fees collected (our mock token)
        address paymentTokenAddress = vm.envAddress("TOKEN_ADDRESS");

        // The user proposing the transaction
        uint256 proposerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proposerAddress = vm.addr(proposerPrivateKey);

        // --- Script Configuration ---
        // This is the address that will receive the withdrawn fees.
        // For this example, we'll send them to the proposer's address.
        address feeRecipient = proposerAddress;
        string memory description = string(
            abi.encodePacked(
                "Proposal #2: Withdraw accumulated marketplace fees. Nonce: ", vm.toString(block.timestamp)
            )
        );

        // --- Contract Instances ---
        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));
        IERC20 paymentToken = IERC20(paymentTokenAddress);

        // --- Build Proposal ---
        uint256 amountToWithdraw = paymentToken.balanceOf(treasuryAddress);
        require(amountToWithdraw > 0, "Treasury has no fees to withdraw. Please run the marketplace scripts first.");

        address[] memory targets = new address[](1);
        targets[0] = treasuryAddress;

        uint256[] memory values = new uint256[](1); // 0 ETH
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeWithSelector(Treasury.withdrawERC20.selector, paymentTokenAddress, feeRecipient, amountToWithdraw);

        console.log("--- Creating Governance Proposal ---");
        console.log("Governor Contract:", governorAddress);
        console.log("Proposer:", proposerAddress);
        console.log("Target Contract (Treasury):", targets[0]);
        console.log("Fee Recipient:", feeRecipient);
        console.log("Token to Withdraw:", paymentTokenAddress);
        console.log("Amount to Withdraw:", amountToWithdraw);
        console.log("Description:", description);

        // --- Execute Transaction ---
        vm.startBroadcast(proposerPrivateKey);

        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.stopBroadcast();

        console.log("\nProposal created successfully!");
        console.log("Proposal ID:", proposalId);
        console.log("You can now vote on this proposal using the Vote.s.sol script.");
    }
}
