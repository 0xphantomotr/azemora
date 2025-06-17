// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AzemoraGovernor} from "../../src/governance/AzemoraGovernor.sol";
import {Treasury} from "../../src/governance/Treasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title QueueScript
 * @dev A script to queue a passed governance proposal.
 */
contract QueueScript is Script {
    function run(uint256 proposalId) external {
        // --- Load Config ---
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address treasuryAddress = vm.envAddress("TREASURY_ADDRESS");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        uint256 proposerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proposerAddress = vm.addr(proposerPrivateKey);

        // --- Re-calculate Proposal Details ---
        // The calldata for the proposal needs to be reconstructed to get its hash.
        uint256 amountToWithdraw = IERC20(tokenAddress).balanceOf(treasuryAddress);

        address[] memory targets = new address[](1);
        targets[0] = treasuryAddress;

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeWithSelector(Treasury.withdrawERC20.selector, tokenAddress, proposerAddress, amountToWithdraw);

        string memory description = "Proposal #1: Withdraw accumulated marketplace fees to the proposer's address.";
        bytes32 descriptionHash = keccak256(bytes(description));

        // --- Queue the Proposal ---
        vm.startBroadcast(proposerPrivateKey);

        AzemoraGovernor governor = AzemoraGovernor(payable(governorAddress));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.stopBroadcast();

        console.log("\nProposal queued successfully!");
        console.log("  Proposal ID:", proposalId);
    }
}
