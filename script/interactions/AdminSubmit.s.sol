// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DMRVManager} from "../../src/core/dMRVManager.sol";

contract AdminSubmit is Script {
    function run() external {
        address dmrvManagerAddress = vm.envAddress("DMRV_MANAGER_ADDRESS");
        bytes32 projectId = vm.envBytes32("TEST_PROJECT_ID");
        uint256 creditAmount = 50 * 1e18; // 50 credits
        string memory credentialCID = "ipfs://admin_submitted_test_credential";

        console.log("Attempting to call adminSubmitVerification as wallet owner...");

        vm.startBroadcast();

        DMRVManager(dmrvManagerAddress).adminSubmitVerification(
            projectId,
            creditAmount,
            credentialCID,
            false // We want to mint credits, not just update metadata
        );

        vm.stopBroadcast();

        console.log("Admin submission successful!");
    }
}
