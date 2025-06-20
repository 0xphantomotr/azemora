// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title AzemoraSmartWallet
 * @author Genci Mehmeti
 * @dev A simple, single-owner smart contract wallet for Azemora users.
 * Implements the EIP-4337 IAccount interface. It can execute arbitrary calls
 * and validates UserOperations based on the owner's signature.
 * Now upgradeable and initializable for use with a proxy factory.
 */
contract AzemoraSmartWallet is IAccount, Initializable {
    // Constants for signature validation
    uint256 private constant SIG_VALIDATION_SUCCESS = 0;
    uint256 private constant SIG_VALIDATION_FAILED = 1;

    IEntryPoint public entryPoint;
    address public owner;

    // The constructor is now empty for use with proxies.
    constructor() {}

    /**
     * @dev Initializes the smart wallet. Can only be called once.
     * @param _entryPoint The address of the EntryPoint contract.
     * @param _owner The address of the wallet owner.
     */
    function initialize(IEntryPoint _entryPoint, address _owner) public initializer {
        entryPoint = _entryPoint;
        owner = _owner;
    }

    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        view
        returns (uint256 validationData)
    {
        if (owner != ECDSA.recover(userOpHash, userOp.signature)) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 /* missingAccountFunds */ )
        external
        view
        override
        returns (uint256 validationData)
    {
        require(msg.sender == address(entryPoint), "AzemoraSmartWallet: caller must be EntryPoint");

        validationData = _validateSignature(userOp, userOpHash);
        if (validationData == SIG_VALIDATION_FAILED) {
            return SIG_VALIDATION_FAILED;
        }

        return SIG_VALIDATION_SUCCESS;
    }

    function execute(address dest, uint256 value, bytes calldata func) external {
        _requireFromEntryPointOrOwner();
        _execute(dest, value, func);
    }

    function executeBatch(address[] calldata dest, bytes[] calldata func) external {
        _requireFromEntryPointOrOwner();
        for (uint256 i = 0; i < dest.length; i++) {
            _execute(dest[i], 0, func[i]);
        }
    }

    function _execute(address dest, uint256 value, bytes calldata func) internal {
        (bool success,) = dest.call{value: value}(func);
        if (!success) {
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _requireFromEntryPointOrOwner() internal view {
        if (msg.sender != address(entryPoint) && msg.sender != owner) {
            revert("AzemoraSmartWallet: sender must be owner or entry point");
        }
    }

    receive() external payable {}
}
