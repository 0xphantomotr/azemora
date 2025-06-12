// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// --- Custom Interfaces to avoid import issues ---

interface IERC165Upgradeable {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// Interface for ERC1155 functionality
interface IERC1155Upgradeable is IERC165Upgradeable {
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch(
        address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values
    );
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);

    function balanceOf(address account, uint256 id) external view returns (uint256);

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory);

    function setApprovalForAll(address operator, bool approved) external;

    function isApprovedForAll(address account, address operator) external view returns (bool);

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;
}

// Interface for ERC20 functionality, included directly to avoid import issues.
interface IERC20Upgradeable {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title Marketplace
 * @author Genci Mehmeti
 * @dev A custodial marketplace for trading ERC1155-based environmental assets.
 * Sellers list their assets by transferring them to this contract. Buyers can then
 * purchase these assets using a designated ERC20 payment token. The contract
 * supports partial purchases and includes a platform fee on sales.
 * It is upgradeable using the UUPS pattern.
 */
contract Marketplace is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC1155HolderUpgradeable,
    PausableUpgradeable
{
    // --- Roles ---
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32[] private _roles;

    // --- State ---
    IERC1155Upgradeable public creditContract;
    IERC20Upgradeable public paymentToken;
    address public treasury;
    uint256 public feeBps; // Fee in basis points (e.g., 250 = 2.5%)

    struct Listing {
        uint256 id;
        address seller;
        uint256 tokenId;
        uint256 amount;
        uint256 pricePerUnit; // Price per single unit of the token
        uint256 expiryTimestamp; // Timestamp when the listing expires
        bool active;
    }

    mapping(uint256 => Listing) public listings;
    uint256 public listingIdCounter;
    uint256 public activeListingCount;

    uint256[50] private __gap;

    // --- Events ---
    event Listed(
        uint256 indexed listingId, address indexed seller, uint256 indexed tokenId, uint256 amount, uint256 pricePerUnit
    );
    event Sold(uint256 indexed listingId, address indexed buyer, uint256 amount, uint256 totalPrice);
    event ListingCancelled(uint256 indexed listingId);
    event ListingPriceUpdated(uint256 indexed listingId, uint256 newPricePerUnit);
    event TreasuryUpdated(address indexed newTreasury);
    event FeeUpdated(uint256 newFeeBps);
    event PartialSold(uint256 indexed listingId, address indexed buyer, uint256 amount, uint256 totalPrice);
    event FeePaid(address indexed recipient, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address creditContract_, address paymentToken_) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __ERC1155Holder_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());

        creditContract = IERC1155Upgradeable(creditContract_);
        paymentToken = IERC20Upgradeable(paymentToken_);

        _roles.push(DEFAULT_ADMIN_ROLE);
        _roles.push(PAUSER_ROLE);
    }

    /**
     * @notice Lists a specified amount of an ERC1155 token for sale.
     * @dev The seller must first approve the marketplace to transfer their tokens.
     * The tokens are held in custody by this contract until sold or unlisted.
     * @param tokenId The ID of the token to list.
     * @param amount The quantity of the token to list.
     * @param pricePerUnit The price for each single unit of the token in the payment currency.
     * @param expiryDuration The duration in seconds after which the listing will expire.
     * @return listingId The unique ID of the newly created listing.
     */
    function list(uint256 tokenId, uint256 amount, uint256 pricePerUnit, uint256 expiryDuration)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 listingId)
    {
        require(amount > 0, "Marketplace: Amount must be > 0");
        require(pricePerUnit > 0, "Marketplace: Price must be > 0");
        require(expiryDuration > 0, "Marketplace: Expiry must be > 0");

        // Custodial model: Transfer tokens from seller to this contract
        creditContract.safeTransferFrom(_msgSender(), address(this), tokenId, amount, "");

        listingId = listingIdCounter++;
        listings[listingId] = Listing({
            id: listingId,
            seller: _msgSender(),
            tokenId: tokenId,
            amount: amount,
            pricePerUnit: pricePerUnit,
            expiryTimestamp: block.timestamp + expiryDuration,
            active: true
        });

        activeListingCount++;

        emit Listed(listingId, _msgSender(), tokenId, amount, pricePerUnit);
        return listingId;
    }

    /**
     * @notice Purchases a specified amount of tokens from an active listing.
     * @dev The buyer must first approve the marketplace to spend their payment tokens.
     * The function handles payment transfers to the seller and the fee recipient,
     * and transfers the purchased tokens to the buyer. Supports partial buys.
     * @param listingId The ID of the listing to buy from.
     * @param amountToBuy The quantity of tokens to purchase from the listing.
     */
    function buy(uint256 listingId, uint256 amountToBuy) external nonReentrant whenNotPaused {
        Listing storage listing = listings[listingId];
        // --- CHECKS ---
        require(listing.active, "Marketplace: Listing not active");
        require(block.timestamp < listing.expiryTimestamp, "Marketplace: Listing expired");
        require(amountToBuy > 0, "Marketplace: Amount must be > 0");
        require(listing.amount >= amountToBuy, "Marketplace: Not enough items in listing");

        uint256 totalPrice = amountToBuy * listing.pricePerUnit;
        require(paymentToken.balanceOf(_msgSender()) >= totalPrice, "Marketplace: Insufficient balance");

        uint256 fee = (totalPrice * feeBps) / 10000;
        uint256 sellerProceeds = totalPrice - fee;

        // --- EFFECTS ---
        listing.amount -= amountToBuy;
        if (listing.amount == 0) {
            listing.active = false;
            activeListingCount--;
            emit Sold(listingId, _msgSender(), amountToBuy, totalPrice);
        } else {
            emit PartialSold(listingId, _msgSender(), amountToBuy, totalPrice);
        }

        // --- INTERACTIONS ---
        // Transfer payment from buyer to seller and fee recipient
        if (sellerProceeds > 0) {
            paymentToken.transferFrom(_msgSender(), listing.seller, sellerProceeds);
        }
        if (fee > 0) {
            paymentToken.transferFrom(_msgSender(), treasury, fee);
            emit FeePaid(treasury, fee);
        }

        // Transfer the NFT from marketplace to buyer
        creditContract.safeTransferFrom(address(this), _msgSender(), listing.tokenId, amountToBuy, "");
    }

    /**
     * @notice Cancels an active listing.
     * @dev Can only be called by the original seller. Any unsold tokens are
     * returned from custody to the seller.
     * @param listingId The ID of the listing to cancel.
     */
    function cancelListing(uint256 listingId) external nonReentrant whenNotPaused {
        Listing storage listing = listings[listingId];
        require(listing.active, "Marketplace: Listing not active");
        require(listing.seller == _msgSender(), "Marketplace: Not the seller");

        listing.active = false;
        activeListingCount--;

        // Return the unsold tokens to the seller
        creditContract.safeTransferFrom(address(this), listing.seller, listing.tokenId, listing.amount, "");

        emit ListingCancelled(listingId);
    }

    /**
     * @notice Cancels an expired listing.
     * @dev Can be called by anyone to clean up an expired listing. The unsold
     * tokens are returned from custody to the seller.
     * @param listingId The ID of the expired listing to cancel.
     */
    function cancelExpiredListing(uint256 listingId) external nonReentrant whenNotPaused {
        Listing storage listing = listings[listingId];
        require(listing.active, "Marketplace: Listing not active");
        require(block.timestamp >= listing.expiryTimestamp, "Marketplace: Listing not expired yet");

        listing.active = false;
        activeListingCount--;

        // Return the unsold tokens to the seller
        creditContract.safeTransferFrom(address(this), listing.seller, listing.tokenId, listing.amount, "");

        emit ListingCancelled(listingId);
    }

    /**
     * @notice Updates the price of an active listing.
     * @dev Can only be called by the original seller.
     * @param listingId The ID of the listing to update.
     * @param newPricePerUnit The new price for each unit in the listing.
     */
    function updateListingPrice(uint256 listingId, uint256 newPricePerUnit) external nonReentrant whenNotPaused {
        Listing storage listing = listings[listingId];
        require(listing.seller == _msgSender(), "Marketplace: Not the seller");
        require(listing.active, "Marketplace: Listing not active");
        require(newPricePerUnit > 0, "Marketplace: Price must be > 0");

        listing.pricePerUnit = newPricePerUnit;
        emit ListingPriceUpdated(listingId, newPricePerUnit);
    }

    /**
     * @notice Sets the address that will receive platform fees.
     * @dev Admin-only function.
     * @param newTreasury The new address for fee collection.
     */
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Marketplace: Zero address");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Sets the platform fee percentage.
     * @dev Admin-only function. Fee is capped to prevent excessive charges.
     * @param newFeeBps The new fee in basis points (e.g., 250 for 2.5%).
     */
    function setFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeBps <= 1000, "Marketplace: Fee cannot exceed 10%"); // Capped at 10%
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /**
     * @notice Retrieves the details of a specific listing.
     * @param listingId The ID of the listing to query.
     * @return A `Listing` struct containing the listing's data.
     */
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    /**
     * @notice Gets all the roles held by a specific account.
     * @dev Provides an easy way for UIs and other tools to check permissions.
     * @param account The address to check.
     * @return A list of role identifiers held by the account.
     */
    function getRoles(address account) external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _roles.length; i++) {
            if (hasRole(_roles[i], account)) {
                count++;
            }
        }

        bytes32[] memory roles = new bytes32[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < _roles.length; i++) {
            if (hasRole(_roles[i], account)) {
                roles[index++] = _roles[i];
            }
        }
        return roles;
    }

    /**
     * @notice Pauses the contract, halting all listing, buying, and cancelling.
     * @dev Can only be called by an address with the PAUSER_ROLE.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract, resuming normal operation.
     * @dev Can only be called by an address with the PAUSER_ROLE.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- Interface Support ---
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, ERC1155HolderUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
