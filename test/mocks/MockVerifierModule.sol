// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerifierModule} from "../../src/core/interfaces/IVerifierModule.sol";

contract MockVerifierModule is IVerifierModule {
    bytes32 public lastClaimId;
    bytes32 public lastProjectId;
    bytes public lastData;
    address public lastOriginalSender;
    string public lastEvidenceURI;

    function startVerificationTask(bytes32 projectId, bytes32 claimId, string calldata evidenceURI)
        external
        override
        returns (bytes32 taskId)
    {
        lastProjectId = projectId;
        lastClaimId = claimId;
        lastEvidenceURI = evidenceURI;
        return keccak256(abi.encodePacked(projectId, claimId, evidenceURI));
    }

    function getModuleName() external pure override returns (string memory) {
        return "MockVerifier_v1";
    }
}
