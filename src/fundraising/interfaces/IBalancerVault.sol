// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBalancerVault
 * @dev A minimal interface for the Balancer V2 Vault, focusing on the `joinPool` function
 * which is used to add initial liquidity to a pool.
 */
interface IBalancerVault {
    /**
     * @dev The different kinds of pool management actions.
     */
    enum ActionId {
        JOIN,
        EXIT
    }

    /**
     * @dev Encapsulates the parameters of a joinPool request.
     * @param assets The pool tokens.
     * @param maxAmountsIn The maximum amounts of tokens to send to the pool.
     * @param userData ABI-encoded data with joining instructions.
     * @param fromInternalBalance True if the tokens are already in the Vault.
     */
    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    /**
     * @notice Adds liquidity to a pool.
     * @param poolId The ID of the pool to join.
     * @param sender The address that is sending the tokens.
     * @param recipient The address that will receive the LP tokens.
     * @param request The parameters for the join operation.
     */
    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest calldata request) external;
}
