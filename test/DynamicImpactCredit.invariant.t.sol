// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../src/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Handler contract to perform actions on the credit contract
contract CreditHandler is Test {
    DynamicImpactCredit credit;
    address admin;
    address minter;
    address[] users;
    mapping(address => mapping(uint256 => uint256)) public userBalances;
    mapping(uint256 => uint256) public totalSupply;
    mapping(uint256 => uint256) public retiredAmount;
    
    // Track which token IDs have been minted
    uint256[] public mintedTokenIds;
    mapping(uint256 => bool) public tokenIdExists;
    
    constructor(DynamicImpactCredit _credit, address _admin, address _minter) {
        credit = _credit;
        admin = _admin;
        minter = _minter;
        
        // Create a set of test users
        for (uint i = 0; i < 5; i++) {
            users.push(address(uint160(0x1000 + i)));
        }
    }
    
    // Add a function to get the length of mintedTokenIds
    function getMintedTokenIdsLength() public view returns (uint256) {
        return mintedTokenIds.length;
    }
    
    // Mint credits to a random user
    function mintCredits(uint256 tokenIdSeed, uint256 amount, string calldata uri) public {
        // Ensure tokenId is a reasonable value and not zero
        uint256 tokenId = (tokenIdSeed % 100) + 1;
        amount = bound(amount, 1, 10000);
        
        // Select a random user
        address user = users[tokenIdSeed % users.length];
        
        vm.prank(minter);
        credit.mintCredits(user, tokenId, amount, uri);
        
        // Track state for invariant testing
        userBalances[user][tokenId] += amount;
        totalSupply[tokenId] += amount;
        
        // Track this token ID
        if (!tokenIdExists[tokenId]) {
            mintedTokenIds.push(tokenId);
            tokenIdExists[tokenId] = true;
        }
    }
    
    // Retire credits for a user
    function retireCredits(uint256 tokenIdSeed, uint256 amountSeed) public {
        if (mintedTokenIds.length == 0) return;
        
        // Select an existing token ID
        uint256 tokenIndex = tokenIdSeed % mintedTokenIds.length;
        uint256 tokenId = mintedTokenIds[tokenIndex];
        
        // Select a user who might have this token
        address user = users[tokenIdSeed % users.length];
        
        // Skip if user has no tokens
        if (userBalances[user][tokenId] == 0) return;
        
        // Determine retire amount (cannot exceed balance)
        uint256 retireAmount = (amountSeed % userBalances[user][tokenId]) + 1;
        
        vm.prank(user);
        try credit.retire(user, tokenId, retireAmount) {
            // Track state changes
            userBalances[user][tokenId] -= retireAmount;
            retiredAmount[tokenId] += retireAmount;
        } catch {
            // If retire fails, that's okay - we're just testing invariants
        }
    }
    
    // Transfer credits between users
    function transferCredits(uint256 tokenIdSeed, uint256 fromUserSeed, uint256 toUserSeed, uint256 amountSeed) public {
        if (mintedTokenIds.length == 0) return;
        
        // Select an existing token ID
        uint256 tokenIndex = tokenIdSeed % mintedTokenIds.length;
        uint256 tokenId = mintedTokenIds[tokenIndex];
        
        // Select different from/to users
        address from = users[fromUserSeed % users.length];
        address to = users[(fromUserSeed + toUserSeed + 1) % users.length];
        if (from == to) to = users[(toUserSeed + 2) % users.length];
        
        // Skip if from user has no tokens
        if (userBalances[from][tokenId] == 0) return;
        
        // Determine transfer amount (cannot exceed balance)
        uint256 transferAmount = (amountSeed % userBalances[from][tokenId]) + 1;
        
        vm.prank(from);
        try credit.safeTransferFrom(from, to, tokenId, transferAmount, "") {
            // Track state changes
            userBalances[from][tokenId] -= transferAmount;
            userBalances[to][tokenId] += transferAmount;
        } catch {
            // If transfer fails, that's okay - we're just testing invariants
        }
    }
    
    // Update token URI (only used by admin)
    function updateTokenURI(uint256 tokenIdSeed, string calldata newURI) public {
        if (mintedTokenIds.length == 0) return;
        
        // Select an existing token ID
        uint256 tokenIndex = tokenIdSeed % mintedTokenIds.length;
        uint256 tokenId = mintedTokenIds[tokenIndex];
        
        vm.prank(admin);
        credit.setTokenURI(tokenId, newURI);
    }
    
    // Helper function to get total minted credits across all users
    function getTotalUserBalance(uint256 tokenId) public view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < users.length; i++) {
            total += userBalances[users[i]][tokenId];
        }
        return total;
    }
}

// Fix: The correct inheritance order is StdInvariant first, then Test
contract DynamicImpactCreditInvariantTest is StdInvariant, Test {
    DynamicImpactCredit credit;
    CreditHandler handler;
    address admin = address(0xA11CE);
    address minter = address(0xB01D);
    
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
        
        // Create handler and target it for invariant testing
        handler = new CreditHandler(credit, admin, minter);
        targetContract(address(handler));
    }
    
    // Invariant: For each token ID, the sum of all user balances should equal total supply minus retired amount
    function invariant_balancesMatchSupply() public {
        uint256 numTokens = handler.getMintedTokenIdsLength();
        for (uint i = 0; i < numTokens; i++) {
            uint256 tokenId = handler.mintedTokenIds(i);
            uint256 onChainTotalBalance = handler.getTotalUserBalance(tokenId);
            
            assertEq(
                onChainTotalBalance + handler.retiredAmount(tokenId),
                handler.totalSupply(tokenId),
                "Total balances + retired should equal total supply"
            );
        }
    }
    
    // Invariant: User balances tracked in the handler should match balances on the contract
    function invariant_handlerBalancesMatchContract() public {
        address[] memory users = new address[](5);
        for (uint i = 0; i < 5; i++) {
            users[i] = address(uint160(0x1000 + i));
        }
        
        uint256 numTokens = handler.getMintedTokenIdsLength();
        for (uint i = 0; i < numTokens; i++) {
            uint256 tokenId = handler.mintedTokenIds(i);
            
            for (uint j = 0; j < users.length; j++) {
                address user = users[j];
                assertEq(
                    handler.userBalances(user, tokenId),
                    credit.balanceOf(user, tokenId),
                    "Handler balances should match contract balances"
                );
            }
        }
    }
    
    // Invariant: Admin role should never change
    function invariant_adminRoleNeverChanges() public {
        assertTrue(
            credit.hasRole(credit.DEFAULT_ADMIN_ROLE(), admin),
            "Admin should always have admin role"
        );
    }
    
    // Invariant: Minter role should never change
    function invariant_minterRoleNeverChanges() public {
        assertTrue(
            credit.hasRole(credit.MINTER_ROLE(), minter),
            "Minter should always have minter role"
        );
    }
} 