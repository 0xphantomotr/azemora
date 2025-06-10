// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./ProjectRegistry.sol";
import "./DynamicImpactCredit.sol";

/**
 * @title dMRVManager
 * @dev Manages the retrieval and processing of digital Monitoring, Reporting, and 
 * Verification (dMRV) data for climate projects. This contract serves as the bridge between
 * off-chain dMRV systems and on-chain tokens, ensuring that only verified environmental
 * impact is represented in the DynamicImpactCredit tokens.
 * 
 * For MVP purposes, this uses a simplified oracle approach, with plans to connect to
 * Chainlink in a future version.
 */
contract DMRVManager is 
    Initializable, 
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // --- Roles ---
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // --- State variables ---
    ProjectRegistry public projectRegistry;
    DynamicImpactCredit public creditContract;
    
    // Mapping to track verification requests by request ID
    mapping(bytes32 => VerificationRequest) private _requests;
    
    // Structure for tracking verification requests
    struct VerificationRequest {
        bytes32 projectId;
        address requestor;
        uint256 timestamp;
        bool fulfilled;
    }
    
    // Structure for representing parsed verification data
    struct VerificationData {
        uint256 creditAmount;
        string metadataURI;
        bool updateMetadataOnly;
        bytes32 signature; // For validating that data came from an authorized source
    }

    // --- Events ---
    event VerificationRequested(bytes32 indexed requestId, bytes32 indexed projectId, address indexed requestor);
    event VerificationFulfilled(bytes32 indexed requestId, bytes32 indexed projectId, uint256 creditAmount);
    event MetadataUpdated(bytes32 indexed projectId, string newURI);
    event CreditsMinted(bytes32 indexed projectId, address indexed owner, uint256 amount);
    event MissingProjectError(bytes32 indexed projectId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address projectRegistry_, address creditContract_) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        // In a real deployment, this would be set to trusted oracle addresses
        _grantRole(ORACLE_ROLE, _msgSender()); 

        projectRegistry = ProjectRegistry(projectRegistry_);
        creditContract = DynamicImpactCredit(creditContract_);
    }

    /**
     * @notice Requests verification data for a specific project from the oracle network
     * @dev This initiates the off-chain data retrieval process. In the production version,
     * this would make an actual Chainlink request.
     * @param projectId The unique identifier of the project to verify
     * @return requestId A unique identifier for this verification request
     */
    function requestVerification(bytes32 projectId) 
        external 
        nonReentrant 
        returns (bytes32 requestId) 
    {
        require(projectRegistry.isProjectActive(projectId), "DMRVManager: Project not active");
        
        // For MVP: Generate a simple request ID.
        // In production, this would come from the Chainlink request.
        requestId = keccak256(abi.encodePacked(projectId, _msgSender(), block.timestamp));
        
        _requests[requestId] = VerificationRequest({
            projectId: projectId,
            requestor: _msgSender(),
            timestamp: block.timestamp,
            fulfilled: false
        });
        
        emit VerificationRequested(requestId, projectId, _msgSender());
        
        // In a real implementation, we'd make a Chainlink request here.
        // For MVP purposes, we're simulating the oracle callback.
        
        return requestId;
    }

    /**
     * @notice Callback function for oracles to deliver verification data
     * @dev Only callable by addresses with the ORACLE_ROLE.
     * @param requestId The ID of the verification request being fulfilled
     * @param data The encoded verification data from the dMRV system
     */
    function fulfillVerification(bytes32 requestId, bytes calldata data) 
        external 
        onlyRole(ORACLE_ROLE) 
        nonReentrant 
    {
        VerificationRequest storage request = _requests[requestId];
        require(request.timestamp > 0, "DMRVManager: Request not found");
        require(!request.fulfilled, "DMRVManager: Request already fulfilled");
        
        request.fulfilled = true;
        
        // Process the verification data
        VerificationData memory vData = parseVerificationData(data);
        
        // Act based on the verification data
        processVerification(request.projectId, request.requestor, vData);
        
        emit VerificationFulfilled(requestId, request.projectId, vData.creditAmount);
    }
    
    /**
     * @notice Processes verified dMRV data and takes appropriate action
     * @dev This function routes to either token minting or metadata updates
     * @param projectId The project identifier
     * @param data The parsed verification data
     */
    function processVerification(
        bytes32 projectId, 
        address /* requestor */, 
        VerificationData memory data
    ) 
        internal 
    {
        if (data.updateMetadataOnly) {
            // Update metadata only
            creditContract.setTokenURI(projectId, data.metadataURI);
            emit MetadataUpdated(projectId, data.metadataURI);
        } else if (data.creditAmount > 0) {
            // Get project owner from registry to mint credits to them
            try projectRegistry.getProject(projectId) returns (ProjectRegistry.Project memory project) {
                // Mint new credits to the project owner
                creditContract.mintCredits(
                    project.owner, 
                    projectId, 
                    data.creditAmount, 
                    data.metadataURI
                );
                emit CreditsMinted(projectId, project.owner, data.creditAmount);
            } catch {
                emit MissingProjectError(projectId);
            }
        }
    }
    
    /**
     * @notice Parses raw verification data into a structured format
     * @dev This is a simplified version for MVP; would be more robust in production
     * @param data The raw verification data from the oracle
     * @return Parsed verification data
     */
    function parseVerificationData(bytes calldata data) 
        internal 
        pure 
        returns (VerificationData memory) 
    {
        // A more robust decoding scheme.
        (
            uint256 creditAmount,
            bool updateMetadataOnly,
            bytes32 signature,
            string memory metadataURI
        ) = abi.decode(data, (uint256, bool, bytes32, string));
        
        return VerificationData({
            creditAmount: creditAmount,
            metadataURI: metadataURI,
            updateMetadataOnly: updateMetadataOnly,
            signature: signature
        });
    }

    /**
     * @notice Admin function for manually setting verification data (testing/emergency use)
     * @dev Only callable by admin, primarily for testing and contingency
     * @param projectId The project identifier
     * @param creditAmount Amount of credits to mint
     * @param metadataURI URI of the metadata to set
     * @param updateMetadataOnly If true, only update metadata without minting
     */
    function adminSetVerification(
        bytes32 projectId,
        uint256 creditAmount,
        string calldata metadataURI,
        bool updateMetadataOnly
    ) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        nonReentrant 
    {
        require(projectRegistry.isProjectActive(projectId), "DMRVManager: Project not active");
        
        VerificationData memory vData = VerificationData({
            creditAmount: creditAmount,
            metadataURI: metadataURI,
            updateMetadataOnly: updateMetadataOnly,
            signature: bytes32(0) // Not needed for admin functions
        });
        
        processVerification(projectId, _msgSender(), vData);
    }
    
    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address /* newImpl */)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}
}