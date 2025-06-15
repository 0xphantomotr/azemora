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

// --- Custom Errors for Gas Optimization ---
error Marketplace__ZeroAmount();
error Marketplace__ZeroPrice();
error Marketplace__ZeroExpiry();
error Marketplace__ListingNotActive();
error Marketplace__ListingExpired();
error Marketplace__NotEnoughItemsInListing();
error Marketplace__InsufficientBalance();
error Marketplace__NotTheSeller();
error Marketplace__TreasuryAddressZero();
error Marketplace__FeeTooHigh();
error Marketplace__ListingNotFound();
error Marketplace__ArrayLengthMismatch();
error Marketplace__TransferFailed();
error Marketplace__ListingNotExpired();
error Marketplace__AmountTooLarge();
error Marketplace__PriceTooLarge();

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
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC1155HolderUpgradeable
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
        uint256 tokenId;
        // --- Packed for gas efficiency ---
        // Slot 3
        address seller; // 20 bytes
        uint64 expiryTimestamp; // 8 bytes
        bool active; // 1 byte
        // Slot 4
        uint128 pricePerUnit; // 16 bytes
        uint96 amount; // 12 bytes
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

    /**
     * @notice Initializes the marketplace with its core dependencies.
     * @dev Sets up roles and contract dependencies. The deployer is granted `DEFAULT_ADMIN_ROLE`
     * and `PAUSER_ROLE`. The `treasury` and `feeBps` must be set in separate transactions
     * after initialization.
     * @param creditContract_ The address of the ERC1155 `DynamicImpactCredit` contract.
     * @param paymentToken_ The address of the ERC20 token used for payments.
     */
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
     * @dev The seller must have first approved the marketplace to manage their tokens via `setApprovalForAll`.
     * The tokens are held in custody by this contract until sold or the listing is cancelled.
     * Emits a `Listed` event.
     * @param tokenId The ID of the token to list.
     * @param amount The quantity of the token to list.
     * @param pricePerUnit The price for each single unit of the token in the payment currency.
     * @param expiryDuration The duration in seconds from now after which the listing will expire.
     * @return listingId The unique ID of the newly created listing.
     */
    function list(uint256 tokenId, uint256 amount, uint256 pricePerUnit, uint256 expiryDuration)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 listingId)
    {
        if (amount == 0) revert Marketplace__ZeroAmount();
        if (pricePerUnit == 0) revert Marketplace__ZeroPrice();
        if (expiryDuration == 0) revert Marketplace__ZeroExpiry();
        if (amount > type(uint96).max) revert Marketplace__AmountTooLarge();
        if (pricePerUnit > type(uint128).max) revert Marketplace__PriceTooLarge();

        // --- Optimisation: Cache storage read ---
        IERC1155Upgradeable _creditContract = creditContract;

        // Custodial model: Transfer tokens from seller to this contract
        _creditContract.safeTransferFrom(_msgSender(), address(this), tokenId, amount, "");

        listingId = listingIdCounter++;
        listings[listingId] = Listing({
            id: listingId,
            tokenId: tokenId,
            seller: _msgSender(),
            expiryTimestamp: uint64(block.timestamp + expiryDuration),
            active: true,
            pricePerUnit: uint128(pricePerUnit),
            amount: uint96(amount)
        });

        activeListingCount++;

        emit Listed(listingId, _msgSender(), tokenId, amount, pricePerUnit);
        return listingId;
    }

    /**
     * @notice Purchases a specified amount of tokens from an active listing.
     * @dev The buyer must have first approved the marketplace to spend their payment tokens via `approve`.
     * The function handles payment transfers to the seller and the treasury, and transfers the
     * purchased tokens to the buyer. Supports partial buys.
     * Emits a `PartialSold` event or a `Sold` event if the listing is fully depleted.
     * @param listingId The ID of the listing to buy from.
     * @param amountToBuy The quantity of tokens to purchase from the listing.
     */
    function buy(uint256 listingId, uint256 amountToBuy) external nonReentrant whenNotPaused {
        // --- Optimisation: Cache storage reads ---
        Listing storage listing = listings[listingId];
        Listing memory listing_ = listing;
        uint256 feeBps_ = feeBps;
        IERC20Upgradeable paymentToken_ = paymentToken;

        // --- CHECKS ---
        if (!listing_.active) revert Marketplace__ListingNotActive();
        if (block.timestamp >= listing_.expiryTimestamp) revert Marketplace__ListingExpired();
        if (amountToBuy == 0) revert Marketplace__ZeroAmount();
        if (listing_.amount < amountToBuy) revert Marketplace__NotEnoughItemsInListing();

        uint256 totalPrice = amountToBuy * listing_.pricePerUnit;
        if (paymentToken_.balanceOf(_msgSender()) < totalPrice) revert Marketplace__InsufficientBalance();

        uint256 fee = (totalPrice * feeBps_) / 10000;
        uint256 sellerProceeds = totalPrice - fee;

        // --- EFFECTS ---
        listing.amount = uint96(listing_.amount - amountToBuy);
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
            if (!paymentToken_.transferFrom(_msgSender(), listing_.seller, sellerProceeds)) {
                revert Marketplace__TransferFailed();
            }
        }
        if (fee > 0) {
            if (!paymentToken_.transferFrom(_msgSender(), treasury, fee)) {
                revert Marketplace__TransferFailed();
            }
            emit FeePaid(treasury, fee);
        }

        // Transfer the purchased tokens to the buyer
        creditContract.safeTransferFrom(address(this), _msgSender(), listing_.tokenId, amountToBuy, "");
    }

    /**
     * @notice Cancels an active listing.
     * @dev Can only be called by the original seller. Any unsold tokens held in custody are
     * returned to the seller. Emits a `ListingCancelled` event.
     * @param listingId The ID of the listing to cancel.
     */
    function cancelListing(uint256 listingId) external nonReentrant whenNotPaused {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Marketplace__ListingNotActive();
        if (listing.seller != _msgSender()) revert Marketplace__NotTheSeller();

        listing.active = false;
        activeListingCount--;

        // Return the unsold tokens to the seller
        creditContract.safeTransferFrom(address(this), listing.seller, listing.tokenId, listing.amount, "");

        emit ListingCancelled(listingId);
    }

    /**
     * @notice Cancels multiple active listings in a single transaction.
     * @dev Can only be called by the original seller of all listings. Unsold tokens
     * for each cancelled listing are returned to the seller in a single batch transaction,
     * which is more gas-efficient than calling `cancelListing` individually.
     * @param listingIds An array of listing IDs to cancel.
     */
    function batchCancelListings(uint256[] calldata listingIds) external nonReentrant whenNotPaused {
        uint256[] memory tokenIds = new uint256[](listingIds.length);
        uint256[] memory amounts = new uint256[](listingIds.length);
        address seller = _msgSender();

        // Down-counting loop is more gas-efficient.
        for (uint256 i = listingIds.length; i > 0; --i) {
            uint256 listingId = listingIds[i - 1];
            Listing storage listing = listings[listingId];
            if (!listing.active) revert Marketplace__ListingNotActive();
            if (listing.seller != seller) revert Marketplace__NotTheSeller();

            listing.active = false;
            activeListingCount--;

            tokenIds[i - 1] = listing.tokenId;
            amounts[i - 1] = listing.amount;

            emit ListingCancelled(listingId);
        }

        // Return all unsold tokens to the seller in a single batch transaction
        creditContract.safeBatchTransferFrom(address(this), seller, tokenIds, amounts, "");
    }

    /**
     * @notice Purchases tokens from multiple listings in a single transaction.
     * @dev The buyer must have approved the marketplace to spend the total amount of payment tokens.
     * This function iterates through the provided listings and amounts, processes payments,
     * and transfers the purchased tokens to the buyer in a single batch. It is significantly
     * more gas-efficient than calling `buy` multiple times.
     * @param listingIds An array of listing IDs to buy from.
     * @param amountsToBuy An array of token quantities to purchase from each corresponding listing.
     */
    function batchBuy(uint256[] calldata listingIds, uint256[] calldata amountsToBuy)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 len = listingIds.length;
        if (len != amountsToBuy.length) revert Marketplace__ArrayLengthMismatch();

        uint256 totalPayment = 0;
        uint256 totalFee = 0;

        // Arrays to store data from the checks phase for the interactions phase
        uint256[] memory tokenIds = new uint256[](len);
        address[] memory sellers = new address[](len);
        uint256[] memory sellerProceeds = new uint256[](len);

        // ==========================================================
        // 1. CHECKS Phase: Read state, perform all checks, calculate totals.
        // ==========================================================
        for (uint256 i = len; i > 0; --i) {
            uint256 j = i - 1;
            uint256 listingId = listingIds[j];
            uint256 amountToBuy = amountsToBuy[j];
            Listing storage listing = listings[listingId];

            if (!listing.active) revert Marketplace__ListingNotActive();
            if (block.timestamp >= listing.expiryTimestamp) revert Marketplace__ListingExpired();
            if (amountToBuy == 0) revert Marketplace__ZeroAmount();
            if (listing.amount < amountToBuy) revert Marketplace__NotEnoughItemsInListing();

            uint256 price = amountToBuy * listing.pricePerUnit;
            uint256 fee = (price * feeBps) / 10000;

            // Store info for later phases
            totalPayment += price;
            totalFee += fee;
            sellers[j] = listing.seller;
            sellerProceeds[j] = price - fee;
            tokenIds[j] = listing.tokenId;
        }

        if (paymentToken.balanceOf(_msgSender()) < totalPayment) revert Marketplace__InsufficientBalance();

        // ==========================================================
        // 2. EFFECTS Phase: Write all state changes. NO external calls.
        // ==========================================================
        for (uint256 i = len; i > 0; --i) {
            uint256 j = i - 1;
            uint256 listingId = listingIds[j];
            uint256 amountToBuy = amountsToBuy[j];
            Listing storage listing = listings[listingId]; // Get pointer again

            uint256 price = amountToBuy * listing.pricePerUnit;

            listing.amount -= uint96(amountToBuy);
            if (listing.amount == 0) {
                listing.active = false;
                activeListingCount--;
                emit Sold(listingId, _msgSender(), amountToBuy, price);
            } else {
                emit PartialSold(listingId, _msgSender(), amountToBuy, price);
            }
        }

        // ==========================================================
        // 3. INTERACTIONS Phase: All external calls happen here.
        // ==========================================================
        // 3a. Pay Treasury
        if (totalFee > 0) {
            if (!paymentToken.transferFrom(_msgSender(), treasury, totalFee)) {
                revert Marketplace__TransferFailed();
            }
            emit FeePaid(treasury, totalFee);
        }

        // 3b. Pay Sellers
        for (uint256 i = len; i > 0; --i) {
            uint256 j = i - 1;
            if (sellerProceeds[j] > 0) {
                if (!paymentToken.transferFrom(_msgSender(), sellers[j], sellerProceeds[j])) {
                    revert Marketplace__TransferFailed();
                }
            }
        }

        // 3c. Transfer NFTs to buyer
        creditContract.safeBatchTransferFrom(address(this), _msgSender(), tokenIds, amountsToBuy, "");
    }

    /**
     * @notice Cancels an expired listing.
     * @dev Can be called by anyone to clean up an expired listing. The unsold
     * tokens are returned from custody to the seller.
     * @param listingId The ID of the expired listing to cancel.
     */
    function cancelExpiredListing(uint256 listingId) external nonReentrant whenNotPaused {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Marketplace__ListingNotActive();
        if (block.timestamp < listing.expiryTimestamp) revert Marketplace__ListingNotExpired();

        listing.active = false;
        activeListingCount--;

        // Return the unsold tokens to the seller
        creditContract.safeTransferFrom(address(this), listing.seller, listing.tokenId, listing.amount, "");

        emit ListingCancelled(listingId);
    }

    /**
     * @notice Allows a seller to update the price of their active listing.
     * @dev Can only be called by the original seller of the listing.
     * Emits a `ListingPriceUpdated` event.
     * @param listingId The ID of the listing to update.
     * @param newPricePerUnit The new price for each unit of the token.
     */
    function updateListingPrice(uint256 listingId, uint256 newPricePerUnit) external nonReentrant whenNotPaused {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Marketplace__ListingNotActive();
        if (listing.seller != _msgSender()) revert Marketplace__NotTheSeller();
        if (newPricePerUnit == 0) revert Marketplace__ZeroPrice();
        if (newPricePerUnit > type(uint128).max) revert Marketplace__PriceTooLarge();

        listing.pricePerUnit = uint128(newPricePerUnit);
        emit ListingPriceUpdated(listingId, newPricePerUnit);
    }

    /**
     * @notice Sets the address of the treasury contract that receives platform fees.
     * @dev Can only be called by an address with the `DEFAULT_ADMIN_ROLE`.
     * It is recommended this be the Timelock contract in a DAO context.
     * Emits a `TreasuryUpdated` event.
     * @param newTreasury The address of the new treasury.
     */
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert Marketplace__TreasuryAddressZero();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Sets the platform fee in basis points.
     * @dev Can only be called by an address with the `DEFAULT_ADMIN_ROLE`.
     * For example, a value of 250 corresponds to a 2.5% fee.
     * Emits a `FeeUpdated` event.
     * @param newFeeBps The new fee in basis points.
     */
    function setFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // A sanity check to prevent accidentally setting an enormous fee.
        // 10000 bps = 100%
        if (newFeeBps > 10000) revert Marketplace__FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /**
     * @notice Retrieves the details of a specific listing.
     * @param listingId The ID of the listing to query.
     * @return A `Listing` struct containing the listing's data.
     */
    function getListing(uint256 listingId) external view returns (Listing memory) {
        if (listings[listingId].id != listingId) revert Marketplace__ListingNotFound();
        return listings[listingId];
    }

    /**
     * @notice Gets all the roles held by a specific account.
     * @dev Provides an easy way for UIs and other tools to check permissions.
     * @param account The address to check.
     * @return A list of role identifiers held by the account.
     */
    function getRoles(address account) external view returns (bytes32[] memory) {
        // More efficient implementation: loop only once.
        bytes32[] memory temporaryRoles = new bytes32[](_roles.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _roles.length; i++) {
            if (hasRole(_roles[i], account)) {
                temporaryRoles[count] = _roles[i];
                count++;
            }
        }

        bytes32[] memory roles = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            roles[i] = temporaryRoles[i];
        }
        return roles;
    }

    /**
     * @notice Pauses all state-changing functions in the contract.
     * @dev Can only be called by an address with the `PAUSER_ROLE`.
     * This is a critical safety feature to halt activity in case of an emergency.
     * Emits a `Paused` event.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Lifts the pause on the contract, resuming normal operations.
     * @dev Can only be called by an address with the `PAUSER_ROLE`.
     * Emits an `Unpaused` event.
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
