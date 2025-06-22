// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IQuestVerifier.sol";

/**
 * @title IERC721And1155
 * @dev A minimal interface to get the balance of a user for both ERC721 and ERC1155 tokens.
 */
interface IERC721And1155 {
    function balanceOf(address owner) external view returns (uint256);
}

/**
 * @title NftHolderVerifier
 * @dev A quest verifier that checks if a user holds at least one NFT from a specific collection.
 * This contract works for both ERC721 and ERC1155 contracts that have a `balanceOf(address)` function.
 */
contract NftHolderVerifier is IQuestVerifier, Ownable {
    // --- Custom Errors ---
    error NftHolderVerifier__InvalidAddress();

    // --- State ---
    IERC721And1155 public immutable nftCollection;

    /**
     * @param nftCollectionAddress The address of the ERC721 or ERC1155 token contract.
     * @param initialOwner The initial owner of this contract.
     */
    constructor(address nftCollectionAddress, address initialOwner) Ownable(initialOwner) {
        if (nftCollectionAddress == address(0)) revert NftHolderVerifier__InvalidAddress();
        nftCollection = IERC721And1155(nftCollectionAddress);
    }

    // --- IQuestVerifier Implementation ---

    /**
     * @inheritdoc IQuestVerifier
     * @dev Checks if the user's balance in the target NFT collection is greater than 0.
     */
    function verify(address user) external view override returns (bool) {
        return nftCollection.balanceOf(user) > 0;
    }
}
