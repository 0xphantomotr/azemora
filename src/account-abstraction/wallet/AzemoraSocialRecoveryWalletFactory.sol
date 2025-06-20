// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AzemoraSocialRecoveryWallet.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title AzemoraSocialRecoveryWalletFactory
 * @author Genci Mehmeti
 * @dev A factory to deploy new AzemoraSocialRecoveryWallet instances using a gas-efficient proxy pattern (EIP-1167).
 */
contract AzemoraSocialRecoveryWalletFactory {
    address public immutable walletImplementation;
    IEntryPoint public immutable entryPoint;

    constructor(IEntryPoint _entryPoint) {
        // Deploy the implementation contract that all proxies will point to.
        walletImplementation = address(new AzemoraSocialRecoveryWallet());
        entryPoint = _entryPoint;
    }

    /**
     * @dev Creates a new AzemoraSocialRecoveryWallet proxy and returns it.
     * The wallet is initialized with the owner, guardians, threshold and entrypoint.
     * @param owner The owner of the new smart wallet.
     * @param guardians The initial list of guardian addresses for the wallet.
     * @param threshold The number of guardians required to approve a recovery.
     * @param salt A value used to create a unique address.
     * @return proxy The newly created wallet contract instance.
     */
    function createAccount(address owner, address[] calldata guardians, uint256 threshold, uint256 salt)
        external
        returns (address proxy)
    {
        proxy = Clones.cloneDeterministic(walletImplementation, keccak256(abi.encodePacked(owner, salt)));

        // Initialize the new proxy wallet with its social recovery settings.
        (bool success,) = proxy.call(
            abi.encodeWithSelector(
                AzemoraSocialRecoveryWallet.initialize.selector, entryPoint, owner, guardians, threshold
            )
        );
        require(success, "AzemoraSocialRecoveryWalletFactory: failed to initialize wallet");
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
