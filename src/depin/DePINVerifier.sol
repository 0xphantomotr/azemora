// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/interfaces/IVerifierModule.sol";
import "./interfaces/IDePINOracle.sol";
import "../core/interfaces/IDMRVManager.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// --- Custom Errors ---
error DePINVerifier__NotDMRVManager();
error DePINVerifier__ZeroAddress();
error DePINVerifier__AlreadySet();
error DePINVerifier__InvalidEvidenceFormat();
error DePINVerifier__ReadingBelowThreshold(bytes32 sensorId, uint256 actual, uint256 expected);
error DePINVerifier__StaleData(bytes32 sensorId, uint256 lastUpdate, uint256 maxDelta);

/**
 * @title DePINVerifier
 * @dev A verifier module that checks data from a DePIN oracle.
 * This contract implements the IVerifierModule interface and is designed
 * to be registered with the dMRVManager. It acts as a trusted, automated
 * gateway for specific DePIN networks.
 */
contract DePINVerifier is
    IVerifierModule,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    IDePINOracle public oracle;
    IDMRVManager public dMRVManager;

    // --- Events ---
    event DMRVManagerSet(address indexed dmrvManager);

    uint256[48] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract.
     * @param _depinOracle The address of the DePIN oracle contract.
     * @param initialOwner The address to grant the DEFAULT_ADMIN_ROLE to.
     */
    function initialize(address _depinOracle, address initialOwner) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        if (_depinOracle == address(0) || initialOwner == address(0)) {
            revert DePINVerifier__ZeroAddress();
        }

        oracle = IDePINOracle(_depinOracle);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    /**
     * @notice Sets the DMRVManager address.
     * @dev This can only be called once by an admin, creating a permanent,
     * trusted link between this verifier and the manager.
     * Any change would require deploying a new verifier.
     * @param _dmrvManager The address of the DMRVManager contract.
     */
    function setDMRVManager(address _dmrvManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(dMRVManager) != address(0)) {
            revert DePINVerifier__AlreadySet();
        }
        if (_dmrvManager == address(0)) {
            revert DePINVerifier__ZeroAddress();
        }
        dMRVManager = IDMRVManager(_dmrvManager);
        emit DMRVManagerSet(_dmrvManager);
    }

    /**
     * @notice The entry point for the dMRVManager to delegate a verification task.
     * @dev This function contains the core logic for querying the oracle and verifying the data.
     * @param projectId The ID of the project being verified.
     * @param claimId The unique ID for this specific claim.
     * @param evidenceURI A string containing the ABI-encoded `(bytes32 sensorId, uint256 minThreshold, uint256 maxTimeDelta)`.
     */
    function startVerificationTask(bytes32 projectId, bytes32 claimId, string calldata evidenceURI)
        external
        override
        nonReentrant
        returns (bytes32 taskId)
    {
        if (msg.sender != address(dMRVManager)) {
            revert DePINVerifier__NotDMRVManager();
        }

        // 1. Decode the evidence parameters
        (bytes32 sensorId, uint256 minThreshold, uint256 maxTimeDelta) = _decodeEvidence(evidenceURI);

        // 2. Query the oracle
        (uint256 oracleValue, uint256 oracleTimestamp) = oracle.getSensorReading(sensorId);

        // 3. Perform verification checks
        bool isVerified = _verifyReading(sensorId, oracleValue, oracleTimestamp, minThreshold, maxTimeDelta);

        // 4. Format the result for the dMRVManager
        bytes memory resultData;
        if (isVerified) {
            // Success: Signal to mint 1 credit and do not force a metadata update.
            // The dMRVManager can be configured to mint more if needed.
            resultData = abi.encode(uint256(1), false, bytes32(0), "ipfs://depin-verified-v1");
        } else {
            // Failure: Signal to mint 0 credits and force a metadata update to show rejection status.
            resultData = abi.encode(uint256(0), true, bytes32(0), "ipfs://depin-failed-v1");
        }

        // 5. Report the final result back to the dMRVManager
        dMRVManager.fulfillVerification(projectId, claimId, resultData);

        // For this synchronous module, the taskId can simply be the claimId
        return claimId;
    }

    // --- Internal Logic ---

    function _decodeEvidence(string calldata evidenceURI)
        internal
        pure
        returns (bytes32 sensorId, uint256 minThreshold, uint256 maxTimeDelta)
    {
        bytes memory evidenceBytes = bytes(evidenceURI);
        // A tuple of (bytes32, uint256, uint256) is exactly 96 bytes long when ABI encoded.
        if (evidenceBytes.length != 96) {
            revert DePINVerifier__InvalidEvidenceFormat();
        }
        // The try/catch syntax is not valid for abi.decode.
        // It will revert on its own if the data is malformed, which is the desired behavior.
        (sensorId, minThreshold, maxTimeDelta) = abi.decode(evidenceBytes, (bytes32, uint256, uint256));
    }

    function _verifyReading(
        bytes32, /* sensorId */
        uint256 oracleValue,
        uint256 oracleTimestamp,
        uint256 minThreshold,
        uint256 maxTimeDelta
    ) internal view returns (bool) {
        if (oracleValue < minThreshold) {
            return false;
        }
        if (block.timestamp - oracleTimestamp > maxTimeDelta) {
            return false;
        }
        return true;
    }

    // Not supported in this verifier type.
    function delegateVerification(
        bytes32, /* claimId */
        bytes32, /* projectId */
        bytes calldata, /* data */
        address /* originalSender */
    ) external pure override {
        revert("DePINVerifier: Delegation not supported");
    }

    /**
     * @notice Allows the DAO/admin to update the oracle address.
     * @param _newOracle The address of the new DePIN oracle contract.
     */
    function setOracle(address _newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newOracle == address(0)) {
            revert DePINVerifier__ZeroAddress();
        }
        oracle = IDePINOracle(_newOracle);
    }

    function getModuleName() external pure override returns (string memory) {
        return "DePINVerifier_v1";
    }

    function owner() external view override returns (address) {
        // Assumes the first member of the admin role is the conceptual owner.
        return getRoleMember(DEFAULT_ADMIN_ROLE, 0);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
