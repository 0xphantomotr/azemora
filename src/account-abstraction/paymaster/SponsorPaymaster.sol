// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IPaymaster} from "@account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @title SponsorPaymaster
 * @author Genci Mehmeti
 * @dev A self-contained paymaster that sponsors gas fees for specific, whitelisted contract calls.
 * It implements the IPaymaster interface directly to avoid dependency conflicts.
 */
contract SponsorPaymaster is IPaymaster {
    IEntryPoint public immutable entryPoint;
    address public owner;
    mapping(address => bool) public sponsoredContracts;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        owner = newOwner;
    }

    function setContractSponsorship(address contractAddress, bool isSponsored) external onlyOwner {
        sponsoredContracts[contractAddress] = isSponsored;
    }

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256)
        external
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");
        (address target,,) = abi.decode(userOp.callData[4:], (address, uint256, bytes));

        if (!sponsoredContracts[target]) {
            revert("SponsorPaymaster: operation not sponsored");
        }

        return ("", 0);
    }

    function postOp(IPaymaster.PostOpMode, bytes calldata, uint256, uint256) external override {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");
        // No action needed for a pure sponsor paymaster
    }

    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        entryPoint.withdrawStake(withdrawAddress);
    }

    function withdrawTo(address payable withdrawAddress, uint256 amount) public onlyOwner {
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    function deposit() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }
}
