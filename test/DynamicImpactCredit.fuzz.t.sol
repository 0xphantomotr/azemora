// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DynamicImpactCreditFuzzTest is Test {
    DynamicImpactCredit credit;
    address admin = address(0xA11CE);
    address minter = address(0xB01D);
    address user = address(0xCAFE);

    function setUp() public {
        vm.startPrank(admin);
        DynamicImpactCredit impl = new DynamicImpactCredit();
        
        bytes memory initData = abi.encodeCall(
            DynamicImpactCredit.initialize,
            ("ipfs://contract-metadata.json")
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        credit = DynamicImpactCredit(address(proxy));
        
        credit.grantRole(credit.MINTER_ROLE(), minter);
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), admin);
        vm.stopPrank();
    }
    
    // Fuzz test: Batch mint with varying array lengths and contents
    function testFuzz_BatchMintArrays(
        uint8 arraySize,
        uint64 seed
    ) public {
        // Bound arraySize to avoid extreme values
        arraySize = uint8(bound(arraySize, 1, 20));
        
        // Create arrays of proper length
        uint256[] memory ids = new uint256[](arraySize);
        uint256[] memory amounts = new uint256[](arraySize);
        string[] memory uris = new string[](arraySize);
        
        // Generate deterministic but varied data based on seed
        for (uint8 i = 0; i < arraySize; i++) {
            // Ensure unique IDs by using the index
            ids[i] = 1000 * uint256(seed % 1000) + i + 1;
            amounts[i] = uint256(keccak256(abi.encode(seed, "amount", i))) % 1000 + 1;
            uris[i] = string(abi.encodePacked("ipfs://", vm.toString(uint256(keccak256(abi.encode(seed, "uri", i))) % 1000000)));
        }
        
        vm.prank(minter);
        credit.batchMintCredits(user, ids, amounts, uris);
        
        // Verify all tokens were minted with correct amounts and URIs
        for (uint8 i = 0; i < arraySize; i++) {
            assertEq(credit.balanceOf(user, ids[i]), amounts[i], "Balance mismatch for token ID");
            assertEq(credit.uri(ids[i]), uris[i], "URI mismatch for token ID");
        }
    }
    
    // Fuzz test: Retirement with random amounts
    function testFuzz_Retire(
        uint256 tokenId,
        uint256 mintAmount,
        uint256 retireAmount
    ) public {
        // Constrain values to reasonable ranges
        tokenId = bound(tokenId, 1, 1000);
        mintAmount = bound(mintAmount, 1, 1000000);
        retireAmount = bound(retireAmount, 1, mintAmount);
        
        // Mint the tokens
        vm.prank(minter);
        credit.mintCredits(user, tokenId, mintAmount, string(abi.encodePacked("ipfs://token", vm.toString(tokenId))));
        
        // Retire some tokens
        vm.prank(user);
        credit.retire(user, tokenId, retireAmount);
        
        // Verify the remaining balance
        assertEq(credit.balanceOf(user, tokenId), mintAmount - retireAmount);
    }
    
    // Fuzz test: URI updates with random strings
    function testFuzz_URIUpdates(
        uint256 tokenId,
        string calldata initialURI,
        string calldata updatedURI
    ) public {
        tokenId = bound(tokenId, 1, 1000);
        
        // Mint with initial URI
        vm.prank(minter);
        credit.mintCredits(user, tokenId, 100, initialURI);
        
        // Update URI
        vm.prank(admin);
        credit.setTokenURI(tokenId, updatedURI);
        
        // Verify the URI was updated
        assertEq(credit.uri(tokenId), updatedURI);
    }
} 