// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AzemoraSmartWallet.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title AzemoraSmartWalletFactory
 * @author Genci Mehmeti
 * @dev A factory to deploy new AzemoraSmartWallet instances using a gas-efficient proxy pattern (EIP-1167).
 * This version is compatible with account-abstraction/contracts v0.6.0.
 */
contract AzemoraSmartWalletFactory {
    address public immutable walletImplementation;
    IEntryPoint public immutable entryPoint;

    constructor(IEntryPoint _entryPoint) {
        // Deploy the implementation contract that all proxies will point to.
        walletImplementation = address(new AzemoraSmartWallet());
        entryPoint = _entryPoint;
    }

    /**
     * @dev Creates a new AzemoraSmartWallet proxy and returns it.
     * The wallet is initialized with the owner and entrypoint.
     * @param owner The owner of the new smart wallet.
     * @param salt A value used to create a unique address.
     * @return proxy The newly created wallet contract instance.
     */
    function createAccount(address owner, uint256 salt) external returns (address proxy) {
        proxy = Clones.cloneDeterministic(walletImplementation, keccak256(abi.encodePacked(owner, salt)));
        // To initialize, we need to make a call to the new proxy.
        // The AzemoraSmartWallet should have an init(address owner) function.
        // For this example, let's assume AzemoraSmartWallet's constructor can be used for initialization
        // via a proxy, which is not standard. A dedicated initializer function is better.
        // Let's assume an initializer `init(IEntryPoint _entryPoint, address _owner)` exists on the wallet.
        // This requires an update to AzemoraSmartWallet.sol
        (bool success,) = proxy.call(abi.encodeWithSelector(AzemoraSmartWallet.initialize.selector, entryPoint, owner));
        require(success, "AzemoraSmartWalletFactory: failed to initialize wallet");
    }

    /**
     * @dev Calculates the counterfactual address of a wallet without deploying it.
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Clones.predictDeterministicAddress(
            walletImplementation, keccak256(abi.encodePacked(owner, salt)), address(this)
        );
    }
}
