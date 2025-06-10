// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DynamicImpactCredit is
    ERC1155Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant MINTER_ROLE            = keccak256("MINTER_ROLE");
    bytes32 public constant METADATA_UPDATER_ROLE  = keccak256("METADATA_UPDATER_ROLE");

    mapping(uint256 => string) private _tokenURIs;
    string private _contractURI;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();      // protect the impl
    }

    function initialize(string memory contractURI_) public initializer {
        __ERC1155_init("");          // base URI empty – each token has its own
        __AccessControl_init();
        // __UUPSUpgradeable_init(); // This call permanently locks the contract, preventing upgrades. It must be removed.

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // This is required to make the initializer the admin.
        _contractURI = contractURI_;
    }

    /* ---------- mint / batchMint ---------- */
    function mintCredits(
        address to,
        uint256 id,
        uint256 amount,
        string calldata uri_
    ) external onlyRole(MINTER_ROLE)
    {
        _mint(to, id, amount, "");
        if (bytes(_tokenURIs[id]).length == 0) {
            _tokenURIs[id] = uri_;
            emit URI(uri_, id);       // ERC-1155 event
        }
    }

    /* ---------- metadata update ---------- */
    function setTokenURI(uint256 id, string calldata newUri)
        external
        onlyRole(METADATA_UPDATER_ROLE)
    {
        _tokenURIs[id] = newUri;
        emit URI(newUri, id);
    }

    function uri(uint256 id) public view override returns (string memory) {
        return _tokenURIs[id];
    }

    /* ---------- retire / burn ---------- */
    function retire(address from, uint256 id, uint256 amount)
        external
        virtual
    {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "NOT_AUTHORIZED"
        );
        _burn(from, id, amount);
        emit CreditsRetired(from, id, amount);
    }

    event CreditsRetired(address indexed from, uint256 indexed id, uint256 amount);

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
    uint256[] calldata ids,
    uint256[] calldata amounts,
    string[] calldata uris   // 1-to-1 with ids
    ) external onlyRole(MINTER_ROLE)
    {
        require(ids.length == amounts.length && ids.length == uris.length, "LENGTH_MISMATCH");
        _mintBatch(to, ids, amounts, "");
        uint256 len = ids.length;
        for (uint256 i; i < len; ++i) {
            if (bytes(_tokenURIs[ids[i]]).length == 0) {
                _tokenURIs[ids[i]] = uris[i];
                emit URI(uris[i], ids[i]);
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