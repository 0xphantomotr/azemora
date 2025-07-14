// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVerificationData
 * @dev Defines the standard data structures for verification results.
 */
interface IVerificationData {
    /**
     * @notice A standardized struct for returning verification results to the dMRVManager.
     * @param quantitativeOutcome A numerical representation of the verification outcome (e.g., tons of CO2).
     * @param wasArbitrated A boolean flag indicating if the result was determined via arbitration.
     * @param arbitrationDisputeId The ID of the dispute in the ArbitrationCouncil, if applicable.
     * @param credentialCID The IPFS CID of the Verifiable Credential containing detailed evidence.
     */
    struct VerificationResult {
        uint256 quantitativeOutcome;
        bool wasArbitrated;
        uint256 arbitrationDisputeId;
        string credentialCID;
    }
}
