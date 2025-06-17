// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Bonding
 * @dev This contract allows users to bond assets (e.g., DynamicImpactCredits)
 * in exchange for AzemoraToken (AZE) at a discount, subject to a vesting period.
 * The bonded assets are transferred to and held by the Treasury.
 * The contract itself must be funded with AZE by the DAO/Treasury to fulfill claims.
 */
contract Bonding is Ownable, ReentrancyGuard, ERC1155Holder {
    struct BondTerm {
        IERC1155 asset; // The asset contract to be bonded (e.g., DynamicImpactCredit)
        uint256 pricePerAssetInAZE; // How many AZE tokens are given per single unit of the asset
        uint256 vestingPeriod; // Vesting period in seconds
        bool active;
    }

    struct UserBond {
        uint256 amountOwedAZE; // The total amount of AZE the user will receive
        uint256 vestingEndsAt; // Timestamp when the user can claim their AZE
        bool claimed; // Flag to prevent double claims
    }

    IERC20 public immutable azeToken;
    address public immutable treasury;

    // Mapping from the asset's token ID to its bond terms
    mapping(uint256 => BondTerm) public bondTerms;
    // Mapping from user to their active bonds. A user can have multiple bonds.
    mapping(address => UserBond[]) public userBonds;

    event BondCreated(address indexed user, uint256 indexed tokenId, uint256 amountBonded, uint256 azeOwed);
    event BondClaimed(address indexed user, uint256 bondIndex, uint256 amountClaimed);

    constructor(address _azeToken, address _treasury) Ownable(msg.sender) {
        require(_azeToken != address(0), "AZE token cannot be zero address");
        require(_treasury != address(0), "Treasury cannot be zero address");
        azeToken = IERC20(_azeToken);
        treasury = _treasury;
    }

    /**
     * @notice Sets the terms for bonding a specific asset (identified by its token ID).
     * @dev Can only be called by the owner (the DAO/Timelock).
     */
    function setBondTerm(
        uint256 _tokenId,
        address _asset,
        uint256 _pricePerAssetInAZE,
        uint256 _vestingPeriod,
        bool _active
    ) external onlyOwner {
        bondTerms[_tokenId] = BondTerm({
            asset: IERC1155(_asset),
            pricePerAssetInAZE: _pricePerAssetInAZE,
            vestingPeriod: _vestingPeriod,
            active: _active
        });
    }

    /**
     * @notice Allows a user to bond a specific amount of an asset (token ID).
     * @dev The user must have approved this contract to transfer their assets.
     */
    function bond(uint256 _tokenId, uint256 _amount) external nonReentrant {
        BondTerm memory term = bondTerms[_tokenId];
        require(term.active, "This bond term is not active");
        require(_amount > 0, "Cannot bond zero amount");

        // Calculate the amount of AZE owed to the user
        uint256 azeToVest = _amount * term.pricePerAssetInAZE;

        // Create the user's bond vesting schedule
        userBonds[msg.sender].push(
            UserBond({amountOwedAZE: azeToVest, vestingEndsAt: block.timestamp + term.vestingPeriod, claimed: false})
        );

        // Pull the bonded assets from the user and transfer them to the treasury
        term.asset.safeTransferFrom(msg.sender, treasury, _tokenId, _amount, "");

        emit BondCreated(msg.sender, _tokenId, _amount, azeToVest);
    }

    /**
     * @notice Allows a user to claim vested AZE from one of their bonds.
     */
    function claim(uint256 _bondIndex) external nonReentrant {
        UserBond storage userBond = userBonds[msg.sender][_bondIndex];

        require(_bondIndex < userBonds[msg.sender].length, "Index out of bounds");
        require(block.timestamp >= userBond.vestingEndsAt, "Vesting period not over");
        require(!userBond.claimed, "Bond already claimed");

        uint256 amountToClaim = userBond.amountOwedAZE;

        userBond.claimed = true;

        // The bonding contract must be funded with AZE from the Treasury to fulfill claims
        require(azeToken.transfer(msg.sender, amountToClaim), "AZE transfer failed");

        emit BondClaimed(msg.sender, _bondIndex, amountToClaim);
    }

    /**
     * @notice Gets a specific bond for a user.
     * @param _user The address of the user.
     * @param _bondIndex The index of the bond in the user's array.
     * @return The UserBond struct.
     */
    function getUserBond(address _user, uint256 _bondIndex) external view returns (UserBond memory) {
        require(_bondIndex < userBonds[_user].length, "Index out of bounds");
        return userBonds[_user][_bondIndex];
    }
}
