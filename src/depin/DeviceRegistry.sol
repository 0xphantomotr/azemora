// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IDeviceRegistry.sol";

// --- Custom Errors ---
error DeviceRegistry__ZeroAddress();
error DeviceRegistry__DeviceAlreadyRegistered();
error DeviceRegistry__DeviceNotRegistered();
error DeviceRegistry__NotOwner();
error DeviceRegistry__OracleAlreadyAuthorized();
error DeviceRegistry__OracleNotAuthorized();

// --- Events ---
event DeviceRegistered(bytes32 indexed deviceId, uint256 indexed tokenId, address indexed initialOwner);

event OracleAuthorized(uint256 indexed tokenId, address indexed oracle);

event OracleDeauthorized(uint256 indexed tokenId, address indexed oracle);

/**
 * @title DeviceRegistry
 * @author Genci Mehmeti
 * @dev Manages the on-chain identity of physical hardware devices using NFTs.
 * Each NFT represents a unique device, creating a verifiable link between the
 * hardware and its authorized data submitter. This contract acts as the
 * foundational layer for a secure DePIN hardware supply chain.
 */
contract DeviceRegistry is
    IDeviceRegistry,
    ERC721EnumerableUpgradeable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable
{
    // --- Roles ---
    bytes32 public constant MANUFACTURER_ROLE = keccak256("MANUFACTURER_ROLE");

    // --- State ---

    // Mapping from the physical device's unique ID to its NFT token ID.
    mapping(bytes32 => uint256) private _deviceToTokenId;

    // Mapping from a device's NFT token ID to its set of authorized oracle addresses.
    mapping(uint256 => mapping(address => bool)) private _authorizedOracles;

    // Counter for minting new tokens. Starts at 1.
    uint256 private _nextTokenId;

    uint256[47] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract, setting up ERC721 and AccessControl.
     * @param name The name of the NFT collection (e.g., "Azemora Trusted Device").
     * @param symbol The symbol of the NFT collection (e.g., "AZD").
     * @param initialAdmin The address to grant the DEFAULT_ADMIN_ROLE to.
     */
    function initialize(string calldata name, string calldata symbol, address initialAdmin) public initializer {
        __ERC721_init(name, symbol);
        __ERC721Enumerable_init();
        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();

        if (initialAdmin == address(0)) revert DeviceRegistry__ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(MANUFACTURER_ROLE, initialAdmin); // Admin is a manufacturer by default

        _nextTokenId = 1; // Start token IDs from 1
    }

    // --- External - Manufacturer Functions ---

    /**
     * @notice Registers a new physical device, minting its corresponding NFT.
     * @dev Only callable by an account with the MANUFACTURER_ROLE.
     *      Creates a permanent, on-chain "birth certificate" for the device.
     * @param deviceId The unique identifier of the physical device (e.g., a hash of its serial number).
     * @param initialOwner The address that will receive the newly minted device NFT.
     * @return tokenId The ID of the newly created NFT.
     */
    function registerDevice(bytes32 deviceId, address initialOwner)
        external
        onlyRole(MANUFACTURER_ROLE)
        returns (uint256)
    {
        if (initialOwner == address(0)) revert DeviceRegistry__ZeroAddress();
        if (_deviceToTokenId[deviceId] != 0) revert DeviceRegistry__DeviceAlreadyRegistered();

        uint256 tokenId = _nextTokenId;
        _nextTokenId++;

        _safeMint(initialOwner, tokenId);
        _deviceToTokenId[deviceId] = tokenId;

        emit DeviceRegistered(deviceId, tokenId, initialOwner);
        return tokenId;
    }

    // --- External - Device Owner Functions ---

    /**
     * @notice Authorizes an oracle to submit data on behalf of a device.
     * @dev Only the owner of the device NFT can call this.
     * @param tokenId The token ID of the device.
     * @param oracle The address of the oracle to authorize.
     */
    function addAuthorizedOracle(uint256 tokenId, address oracle) external {
        if (ownerOf(tokenId) != msg.sender) revert DeviceRegistry__NotOwner();
        if (oracle == address(0)) revert DeviceRegistry__ZeroAddress();
        if (_authorizedOracles[tokenId][oracle]) revert DeviceRegistry__OracleAlreadyAuthorized();

        _authorizedOracles[tokenId][oracle] = true;
        emit OracleAuthorized(tokenId, oracle);
    }

    /**
     * @notice De-authorizes an oracle from submitting data.
     * @dev Only the owner of the device NFT can call this.
     * @param tokenId The token ID of the device.
     * @param oracle The address of the oracle to de-authorize.
     */
    function removeAuthorizedOracle(uint256 tokenId, address oracle) external {
        if (ownerOf(tokenId) != msg.sender) revert DeviceRegistry__NotOwner();
        if (!_authorizedOracles[tokenId][oracle]) revert DeviceRegistry__OracleNotAuthorized();

        _authorizedOracles[tokenId][oracle] = false;
        emit OracleDeauthorized(tokenId, oracle);
    }

    // --- External - View Functions (IDeviceRegistry) ---

    /**
     * @inheritdoc IDeviceRegistry
     */
    function isOracleAuthorizedForDevice(bytes32 deviceId, address oracle) external view override returns (bool) {
        uint256 tokenId = _deviceToTokenId[deviceId];
        if (tokenId == 0) {
            return false;
        }
        return _authorizedOracles[tokenId][oracle];
    }

    /**
     * @inheritdoc IDeviceRegistry
     */
    function getTokenId(bytes32 deviceId) external view override returns (uint256) {
        uint256 tokenId = _deviceToTokenId[deviceId];
        if (tokenId == 0) revert DeviceRegistry__DeviceNotRegistered();
        return tokenId;
    }

    // --- OZ Overrides & Support ---

    function _baseURI() internal pure override returns (string memory) {
        // A production version would point this to a metadata server
        return "https://api.azemora.io/devices/";
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721EnumerableUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IDeviceRegistry).interfaceId || super.supportsInterface(interfaceId);
    }
}
