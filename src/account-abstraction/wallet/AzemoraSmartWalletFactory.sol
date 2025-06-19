// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AzemoraSmartWallet.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";

/**
 * @title AzemoraSmartWalletFactory
 * @author Genci Mehmeti
 * @dev A factory to deploy new AzemoraSmartWallet instances.
 * This version is compatible with account-abstraction/contracts v0.6.0.
 * It is initialized with the EntryPoint address and uses it to deploy new wallets.
 */
contract AzemoraSmartWalletFactory {
    IEntryPoint public immutable entryPoint;

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
    }

    /**
     * @dev Creates a new AzemoraSmartWallet and returns it.
     * The EntryPoint will receive this as an address.
     * @param owner The owner of the new smart wallet.
     * @param salt A value used to create a unique address.
     * @return ret The newly created wallet contract instance.
     */
    function createAccount(address owner, uint256 salt) external returns (AzemoraSmartWallet ret) {
        bytes32 finalSalt = keccak256(abi.encodePacked(owner, salt));
        // The wallet constructor needs the entrypoint address. We pass it from the one stored in this factory.
        ret = new AzemoraSmartWallet{salt: finalSalt}(address(entryPoint), owner);
    }

    /**
     * @dev Calculates the counterfactual address of a wallet without deploying it.
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        bytes32 finalSalt = keccak256(abi.encodePacked(owner, salt));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(AzemoraSmartWallet).creationCode,
                // The constructor arguments must match what's used in createAccount
                abi.encode(address(entryPoint), owner)
            )
        );

        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), finalSalt, bytecodeHash)))));
    }
}
