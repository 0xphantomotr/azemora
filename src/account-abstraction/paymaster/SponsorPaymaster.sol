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
    // Mapping from a target contract address to a mapping of its sponsored function selectors
    mapping(address => mapping(bytes4 => bool)) public sponsoredActions;
    // Mapping to track if a user has already performed a specific sponsored action.
    // user => actionId => bool
    mapping(address => mapping(bytes32 => bool)) public userActionUsed;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "new owner is the zero address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setActionSponsorship(address contractAddress, bytes4 functionSelector, bool isSponsored)
        external
        onlyOwner
    {
        sponsoredActions[contractAddress][functionSelector] = isSponsored;
    }

    function _getActionId(PackedUserOperation calldata userOp) internal pure returns (bytes32) {
        // Create a unique ID for this specific action by hashing the target and selector.
        (address target,, bytes memory innerCallData) = abi.decode(userOp.callData[4:], (address, uint256, bytes));
        bytes4 selector;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            selector := mload(add(innerCallData, 0x20))
        }
        return keccak256(abi.encodePacked(target, selector));
    }

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256)
        external
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");

        // The wallet's `execute` function selector is bytes4(keccak256("execute(address,uint256,bytes)"))
        bytes4 walletExecuteSelector = 0xb61d27f6;
        if (userOp.callData.length < 4 || bytes4(userOp.callData[:4]) != walletExecuteSelector) {
            // Revert if the userOp is not calling the standard `execute` function.
            // This prevents sponsoring other potentially dangerous wallet functions.
            revert("SponsorPaymaster: sponsored action must be via execute()");
        }

        // Decode the arguments of the `execute` call to get the target and the inner call data.
        (address target,, bytes memory innerCallData) = abi.decode(userOp.callData[4:], (address, uint256, bytes));

        // Ensure the inner call data is long enough to contain a function selector.
        if (innerCallData.length < 4) {
            revert("SponsorPaymaster: inner callData too short");
        }
        bytes4 selector;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // The `innerCallData` variable is a pointer to a memory array.
            // The actual data starts 32 bytes after the pointer (where the length is stored).
            // We load the first 32-byte word of the data.
            // The assignment to a bytes4 variable automatically truncates the word to the first 4 bytes.
            selector := mload(add(innerCallData, 0x20))
        }

        if (!sponsoredActions[target][selector]) {
            revert("SponsorPaymaster: action not sponsored");
        }

        // Check if the user has already performed this specific action
        bytes32 actionId = keccak256(abi.encodePacked(target, selector));
        if (userActionUsed[userOp.sender][actionId]) {
            revert("SponsorPaymaster: action already sponsored for this user");
        }

        // Pass the user address and actionId to postOp via the context
        return (abi.encode(userOp.sender, actionId), 0);
    }

    function postOp(IPaymaster.PostOpMode mode, bytes calldata context, uint256, uint256) external override {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");
        // We only mark the action as used if the transaction was successful.
        if (mode == IPaymaster.PostOpMode.opSucceeded) {
            (address user, bytes32 actionId) = abi.decode(context, (address, bytes32));
            userActionUsed[user][actionId] = true;
        }
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
