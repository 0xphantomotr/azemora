// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/fundraising/interfaces/IBalancerVault.sol";

contract MockBalancerVault is IBalancerVault {
    // --- State variables to record call data ---
    bytes32 public last_poolId;
    address public last_sender;
    address public last_recipient;
    JoinPoolRequest public last_request;

    // --- Events ---
    event PoolJoined(
        bytes32 indexed poolId, address indexed sender, address indexed recipient, JoinPoolRequest request
    );

    /**
     * @notice A mock implementation of the joinPool function. It records all arguments
     * and emits an event so that tests can assert that it was called correctly.
     */
    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest calldata request)
        external
        override
    {
        last_poolId = poolId;
        last_sender = sender;
        last_recipient = recipient;
        last_request = request;

        emit PoolJoined(poolId, sender, recipient, request);
    }

    /**
     * @notice A dedicated getter function to return the entire request struct from storage.
     * This is necessary because the default public getter cannot handle dynamic arrays within the struct.
     */
    function getLastRequest() external view returns (JoinPoolRequest memory) {
        return last_request;
    }
}
