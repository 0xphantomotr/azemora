// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMethodologyRegistry
 * @dev Interface for the MethodologyRegistry contract.
 */
interface IMethodologyRegistry {
    /**
     * @notice Checks if a methodology is approved and not deprecated.
     * @param methodologyId The ID of the methodology to check.
     * @return True if the methodology is valid, false otherwise.
     */
    function isMethodologyValid(bytes32 methodologyId) external view returns (bool);

    /**
     * @notice Gets the implementation address for a given methodology.
     * @dev Called by dMRVManager to get the trusted address of a verifier module.
     * @param methodologyId The ID of the methodology.
     * @return The implementation address of the verifier module.
     */
    function getModuleAddress(bytes32 methodologyId) external view returns (address);

    /**
     * @notice Retrieves the full data for a given methodology.
     * @dev This is the public getter for the `methodologies` mapping.
     * @param methodologyId The ID of the methodology to retrieve.
     * @return methodologyId_ The unique ID of the methodology.
     * @return moduleImplementationAddress The contract address for the verifier module.
     * @return methodologySchemaURI The IPFS CID for the methodology document.
     * @return schemaHash The keccak256 hash of the document.
     * @return version The version number of the methodology.
     * @return isApproved The approval status.
     * @return isDeprecated The deprecation status.
     */
    function methodologies(bytes32 methodologyId)
        external
        view
        returns (bytes32, address, string memory, bytes32, uint256, bool, bool);
}
