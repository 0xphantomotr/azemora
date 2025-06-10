// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../src/DynamicImpactCredit.sol";
import "../src/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Handler contract to perform actions on the credit contract
contract CreditHandler is Test {
    DynamicImpactCredit credit;
    ProjectRegistry registry;
    address admin;
    address minter;
    address verifier;
    address[] users;
    mapping(address => mapping(bytes32 => uint256)) public userBalances;
    mapping(bytes32 => uint256) public totalSupply;
    mapping(bytes32 => uint256) public retiredAmount;
    
    // Track which token IDs have been minted
    bytes32[] public mintedTokenIds;
    mapping(bytes32 => bool) public tokenIdExists;
    
    constructor(
        DynamicImpactCredit _credit,
        ProjectRegistry _registry,
        address _admin,
        address _minter,
        address _verifier
    ) {
        credit = _credit;
        registry = _registry;
        admin = _admin;
        minter = _minter;
        verifier = _verifier;
        
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
        bytes32 projectId = keccak256(abi.encodePacked("project", tokenIdSeed % 10));
        amount = bound(amount, 1, 10000);
        
        // Select a random user
        address user = users[tokenIdSeed % users.length];
        
        // Register and approve the project first
        if (!tokenIdExists[projectId]) {
            vm.prank(user); // Project owner registers
            registry.registerProject(projectId, "ipfs://meta.json");
            vm.prank(verifier);
            registry.setProjectStatus(
                projectId,
                ProjectRegistry.ProjectStatus.Active
            );
        }
        
        vm.prank(minter);
        credit.mintCredits(user, projectId, amount, uri);
        
        // Track state for invariant testing
        userBalances[user][projectId] += amount;
        totalSupply[projectId] += amount;
        
        // Track this token ID
        if (!tokenIdExists[projectId]) {
            mintedTokenIds.push(projectId);
            tokenIdExists[projectId] = true;
        }
    }
    
    // Retire credits for a user
    function retireCredits(uint256 tokenIdSeed, uint256 amountSeed) public {
        if (mintedTokenIds.length == 0) return;
        
        // Select an existing token ID
        uint256 tokenIndex = tokenIdSeed % mintedTokenIds.length;
        bytes32 projectId = mintedTokenIds[tokenIndex];
        
        // Select a user who might have this token
        address user = users[tokenIdSeed % users.length];
        
        // Skip if user has no tokens
        if (userBalances[user][projectId] == 0) return;
        
        // Determine retire amount (cannot exceed balance)
        uint256 retireAmount = (amountSeed % userBalances[user][projectId]) + 1;
        
        vm.prank(user);
        try credit.retire(user, projectId, retireAmount) {
            // Track state changes
            userBalances[user][projectId] -= retireAmount;
            retiredAmount[projectId] += retireAmount;
        } catch {
            // If retire fails, that's okay - we're just testing invariants
        }
    }
    
    // Transfer credits between users
    function transferCredits(uint256 tokenIdSeed, uint256 fromUserSeed, uint256 toUserSeed, uint256 amountSeed) public {
        if (mintedTokenIds.length == 0) return;
        
        // Select an existing token ID
        uint256 tokenIndex = tokenIdSeed % mintedTokenIds.length;
        bytes32 projectId = mintedTokenIds[tokenIndex];
        
        // Select different from/to users
        address from = users[fromUserSeed % users.length];
        address to = users[(fromUserSeed + toUserSeed + 1) % users.length];
        if (from == to) to = users[(toUserSeed + 2) % users.length];
        
        // Skip if from user has no tokens
        if (userBalances[from][projectId] == 0) return;
        
        // Determine transfer amount (cannot exceed balance)
        uint256 transferAmount = (amountSeed % userBalances[from][projectId]) + 1;
        
        vm.prank(from);
        try credit.safeTransferFrom(from, to, uint256(projectId), transferAmount, "") {
            // Track state changes
            userBalances[from][projectId] -= transferAmount;
            userBalances[to][projectId] += transferAmount;
        } catch {
            // If transfer fails, that's okay - we're just testing invariants
        }
    }
    
    // Update token URI (only used by admin)
    function updateTokenURI(uint256 tokenIdSeed, string calldata newURI) public {
        if (mintedTokenIds.length == 0) return;
        
        // Select an existing token ID
        uint256 tokenIndex = tokenIdSeed % mintedTokenIds.length;
        bytes32 projectId = mintedTokenIds[tokenIndex];
        
        vm.prank(admin);
        credit.setTokenURI(projectId, newURI);
    }
    
    // Helper function to get total minted credits across all users
    function getTotalUserBalance(bytes32 projectId) public view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < users.length; i++) {
            total += userBalances[users[i]][projectId];
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
    address verifier = address(0xC1E4);
    
    function setUp() public {
        vm.startPrank(admin);
        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        ProjectRegistry registry = ProjectRegistry(address(registryProxy));
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        
        // Deploy Credit Contract
        DynamicImpactCredit impl = new DynamicImpactCredit();
        
        bytes memory initData = abi.encodeCall(
            DynamicImpactCredit.initialize,
            ("ipfs://contract-metadata.json", address(registry))
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        credit = DynamicImpactCredit(address(proxy));
        
        credit.grantRole(credit.MINTER_ROLE(), minter);
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), admin);
        vm.stopPrank();
        
        // Create handler and target it for invariant testing
        handler = new CreditHandler(credit, registry, admin, minter, verifier);
        targetContract(address(handler));
    }
    
    // Invariant: For each token ID, the sum of all user balances should equal total supply minus retired amount
    function invariant_balancesMatchSupply() public view {
        uint256 numTokens = handler.getMintedTokenIdsLength();
        for (uint i = 0; i < numTokens; i++) {
            bytes32 projectId = handler.mintedTokenIds(i);
            uint256 onChainTotalBalance = handler.getTotalUserBalance(projectId);
            
            assertEq(
                onChainTotalBalance + handler.retiredAmount(projectId),
                handler.totalSupply(projectId),
                "Total balances + retired should equal total supply"
            );
        }
    }
    
    // Invariant: User balances tracked in the handler should match balances on the contract
    function invariant_handlerBalancesMatchContract() public view {
        address[] memory users = new address[](5);
        for (uint i = 0; i < 5; i++) {
            users[i] = address(uint160(0x1000 + i));
        }
        
        uint256 numTokens = handler.getMintedTokenIdsLength();
        for (uint i = 0; i < numTokens; i++) {
            bytes32 projectId = handler.mintedTokenIds(i);
            
            for (uint j = 0; j < users.length; j++) {
                address user = users[j];
                assertEq(
                    handler.userBalances(user, projectId),
                    credit.balanceOf(user, uint256(projectId)),
                    "Handler balances should match contract balances"
                );
            }
        }
    }
    
    // Invariant: Admin role should never change
    function invariant_adminRoleNeverChanges() public view {
        assertTrue(
            credit.hasRole(credit.DEFAULT_ADMIN_ROLE(), admin),
            "Admin should always have admin role"
        );
    }
    
    // Invariant: Minter role should never change
    function invariant_minterRoleNeverChanges() public view {
        assertTrue(
            credit.hasRole(credit.MINTER_ROLE(), minter),
            "Minter should always have minter role"
        );
    }
} 