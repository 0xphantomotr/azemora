// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NftHolderVerifier, IERC721And1155} from "../../src/achievements/verifiers/NftHolderVerifier.sol";

// --- Mocks ---
contract MockNFT is IERC721And1155 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// --- Tests ---
contract NftHolderVerifierTest is Test {
    NftHolderVerifier internal verifier;
    MockNFT internal mockNft;

    // --- Users ---
    address internal owner;
    address internal userWithNft;
    address internal userWithoutNft;

    function setUp() public {
        owner = makeAddr("owner");
        userWithNft = makeAddr("userWithNft");
        userWithoutNft = makeAddr("userWithoutNft");

        mockNft = new MockNFT();
        mockNft.mint(userWithNft, 1); // Mint one NFT

        verifier = new NftHolderVerifier(address(mockNft), owner);
    }

    // --- Test Constructor ---

    function test_reverts_constructor_withZeroAddress() public {
        vm.expectRevert(NftHolderVerifier.NftHolderVerifier__InvalidAddress.selector);
        new NftHolderVerifier(address(0), owner);
    }

    // --- Test verify ---

    function test_verify_returnsTrue_forUserWithNft() public view {
        assertTrue(verifier.verify(userWithNft), "Should be true for user with NFT");
    }

    function test_verify_returnsFalse_forUserWithoutNft() public view {
        assertFalse(verifier.verify(userWithoutNft), "Should be false for user without NFT");
    }

    function test_verify_returnsTrue_forUserWithMultipleNfts() public {
        mockNft.mint(userWithNft, 5); // Mint more NFTs
        assertTrue(verifier.verify(userWithNft), "Should be true for user with multiple NFTs");
    }
}
