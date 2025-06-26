// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/interfaces/IVerifierModule.sol";
import "./interfaces/IOracleManager.sol";
import "./interfaces/IRewardCalculator.sol";
import "../core/interfaces/IDMRVManager.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// --- Custom Errors ---
error DePINVerifier__NotDMRVManager();
error DePINVerifier__ZeroAddress();
error DePINVerifier__AlreadySet();
error DePINVerifier__InvalidEvidenceFormat();
error DePINVerifier__ZeroRewardCalculator();

/**
 * @title DePINVerifier
 * @dev A verifier module that checks data by fetching aggregated data from a trusted OracleManager
 * and delegates reward calculations to a specified calculator contract.
 */
contract DePINVerifier is
    IVerifierModule,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    IOracleManager public oracleManager;
    IDMRVManager public dMRVManager;

    // --- Events ---
    event DMRVManagerSet(address indexed dmrvManager);
    event OracleManagerSet(address indexed oracleManager);

    uint256[49] private __gap;

    // --- Structs ---
    struct VerificationTerms {
        bytes32 sensorId;
        bytes32 sensorType;
        address rewardCalculator;
        bytes rewardTerms;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract.
     * @param _dMRVManager The address of the DMRVManager contract.
     * @param _oracleManager The address of the OracleManager contract.
     * @param initialOwner The address to grant the DEFAULT_ADMIN_ROLE to.
     */
    function initialize(address _dMRVManager, address _oracleManager, address initialOwner) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (_dMRVManager == address(0) || _oracleManager == address(0) || initialOwner == address(0)) {
            revert DePINVerifier__ZeroAddress();
        }

        dMRVManager = IDMRVManager(_dMRVManager);
        oracleManager = IOracleManager(_oracleManager);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        emit DMRVManagerSet(_dMRVManager);
        emit OracleManagerSet(_oracleManager);
    }

    /**
     * @notice Sets the DMRVManager address.
     * @dev Can only be called once by an admin.
     * @param _dmrvManager The address of the DMRVManager contract.
     */
    // This function is now deprecated in favor of the single initializer.
    // It can be removed or left as-is, but the new `initialize` is preferred.
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
     * @param projectId The ID of the project being verified.
     * @param claimId The unique ID for this specific claim.
     * @param evidenceURI A string containing the ABI-encoded `VerificationTerms` struct.
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

        VerificationTerms memory terms = _decodeEvidence(evidenceURI);

        if (terms.rewardCalculator == address(0)) {
            revert DePINVerifier__ZeroRewardCalculator();
        }

        IOracleManager.AggregatedReading memory reading =
            oracleManager.getAggregatedReading(terms.sensorId, terms.sensorType);

        uint256 rewardAmount =
            IRewardCalculator(terms.rewardCalculator).calculateReward(terms.rewardTerms, reading.value);

        string memory resultURI = rewardAmount > 0 ? "ipfs://depin-verified-v3" : "ipfs://depin-failed-v3";
        bytes memory resultData = abi.encode(rewardAmount, false, bytes32(0), resultURI);

        dMRVManager.fulfillVerification(projectId, claimId, resultData);

        return claimId;
    }

    // --- Internal Logic ---

    function _decodeEvidence(string calldata evidenceURI) internal pure returns (VerificationTerms memory) {
        bytes memory evidenceBytes = bytes(evidenceURI);
        (VerificationTerms memory terms) = abi.decode(evidenceBytes, (VerificationTerms));
        return terms;
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
     * @notice Allows the DAO/admin to update the oracle manager address.
     * @param _newOracleManager The address of the new OracleManager contract.
     */
    function setOracleManager(address _newOracleManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newOracleManager == address(0)) {
            revert DePINVerifier__ZeroAddress();
        }
        oracleManager = IOracleManager(_newOracleManager);
        emit OracleManagerSet(_newOracleManager);
    }

    function getModuleName() external pure override returns (string memory) {
        return "DePINVerifier_v3_ModularRewards";
    }

    function owner() external view override returns (address) {
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
