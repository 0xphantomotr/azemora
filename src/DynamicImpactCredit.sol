// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./ProjectRegistry.sol";

contract DynamicImpactCredit is
    ERC1155Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant DMRV_MANAGER_ROLE      = keccak256("DMRV_MANAGER_ROLE");
    bytes32 public constant METADATA_UPDATER_ROLE  = keccak256("METADATA_UPDATER_ROLE");

    mapping(uint256 => string) private _tokenURIs;
    string private _contractURI;
    IProjectRegistry public projectRegistry;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();      // protect the impl
    }

    function initialize(string memory contractURI_, address projectRegistry_) public initializer {
        __ERC1155_init("");          // base URI empty – each token has its own
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // This is required to make the initializer the admin.
        _contractURI = contractURI_;
        projectRegistry = IProjectRegistry(projectRegistry_);
    }

    /* ---------- mint / batchMint ---------- */
    function mintCredits(
        address to,
        bytes32 id,
        uint256 amount,
        string calldata uri_
    ) external onlyRole(DMRV_MANAGER_ROLE)
    {
        require(
            projectRegistry.isProjectActive(id),
            "DIC: PROJECT_NOT_ACTIVE"
        );
        uint256 tokenId = uint256(id);
        _mint(to, tokenId, amount, "");
        if (bytes(_tokenURIs[tokenId]).length == 0) {
            _tokenURIs[tokenId] = uri_;
            emit URI(uri_, tokenId);       // ERC-1155 event
        }
    }

    /* ---------- metadata update ---------- */
    function setTokenURI(bytes32 id, string calldata newUri)
        external
        onlyRole(METADATA_UPDATER_ROLE)
    {
        uint256 tokenId = uint256(id);
        _tokenURIs[tokenId] = newUri;
        emit URI(newUri, tokenId);
    }

    function uri(uint256 id) public view override returns (string memory) {
        return _tokenURIs[id];
    }

    /* ---------- retire / burn ---------- */
    function retire(address from, bytes32 id, uint256 amount)
        external
        virtual
    {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "NOT_AUTHORIZED"
        );
        uint256 tokenId = uint256(id);
        _burn(from, tokenId, amount);
        emit CreditsRetired(from, id, amount);
    }

    event CreditsRetired(address indexed from, bytes32 indexed id, uint256 amount);

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address /* newImpl */)
        internal
        virtual
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    /* ---------- interface fan-in ---------- */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function batchMintCredits(
    address to,
    bytes32[] calldata ids,
    uint256[] calldata amounts,
    string[] calldata uris   // 1-to-1 with ids
    ) external onlyRole(DMRV_MANAGER_ROLE)
    {
        require(ids.length == amounts.length && ids.length == uris.length, "LENGTH_MISMATCH");
        
        uint256[] memory tokenIds = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            require(
                projectRegistry.isProjectActive(ids[i]),
                "DIC: PROJECT_NOT_ACTIVE"
            );
            tokenIds[i] = uint256(ids[i]);
        }
        
        _mintBatch(to, tokenIds, amounts, "");

        for (uint256 i = 0; i < ids.length; ++i) {
            if (bytes(_tokenURIs[tokenIds[i]]).length == 0) {
                _tokenURIs[tokenIds[i]] = uris[i];
                emit URI(uris[i], tokenIds[i]);
            }
        }
    }

    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    function setContractURI(string calldata newUri)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _contractURI = newUri;
    }

}