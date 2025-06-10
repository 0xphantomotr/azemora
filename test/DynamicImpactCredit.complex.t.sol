// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Extended V2 implementation with more features
contract DynamicImpactCreditExtendedV2 is DynamicImpactCredit {
    uint256 public constant VERSION = 2;
    
    // New state variables
    mapping(uint256 => uint256) public retirementTimestamps;
    mapping(address => uint256) public totalRetiredByUser;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() DynamicImpactCredit() {
        // constructor is called but implementation remains uninitialized
    }
    
    // Enhanced retire function with timestamps
    function retire(address from, uint256 id, uint256 amount) 
        external 
        override 
    {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "NOT_AUTHORIZED"
        );
        
        _burn(from, id, amount);
        
        // Record timestamp and stats
        retirementTimestamps[id] = block.timestamp;
        totalRetiredByUser[from] += amount;
        
        emit CreditsRetired(from, id, amount);
    }
    
    // New method to get retirement data
    function getRetirementInfo(uint256 id, address user) 
        external 
        view 
        returns (uint256 timestamp, uint256 userTotal) 
    {
        return (retirementTimestamps[id], totalRetiredByUser[user]);
    }
}

interface IUUPS {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract DynamicImpactCreditComplexTest is Test {
    DynamicImpactCredit credit;
    address admin = address(0xA11CE);
    address minter = address(0xB01D);
    
    // Create multiple user addresses
    address user1 = address(0xCAFE);
    address user2 = address(0xBEEF);
    address user3 = address(0xFACE);
    
    // Project data for realistic simulation
    struct Project {
        uint256 id;
        string name;
        string baseURI;
        uint256 initialCredits;
    }
    
    Project[] projects;
    
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
        
        // Set up some realistic projects
        projects.push(Project({
            id: 101,
            name: "Reforestation Project Alpha",
            baseURI: "ipfs://reforest-alpha/metadata-",
            initialCredits: 10000
        }));
        
        projects.push(Project({
            id: 202,
            name: "Solar Farm Beta",
            baseURI: "ipfs://solar-beta/metadata-",
            initialCredits: 5000
        }));
        
        projects.push(Project({
            id: 303,
            name: "Methane Capture Gamma",
            baseURI: "ipfs://methane-gamma/metadata-",
            initialCredits: 7500
        }));
    }
    
    // Complex test: Full lifecycle simulation with dMRV updates
    function testComplex_FullLifecycle() public {
        // STEP 1: Initial project registrations and credit minting
        vm.startPrank(minter);
        
        for (uint i = 0; i < projects.length; i++) {
            // Mint initial credits to user1
            credit.mintCredits(
                user1, 
                projects[i].id, 
                projects[i].initialCredits, 
                string(abi.encodePacked(projects[i].baseURI, "v1.json"))
            );
        }
        
        vm.stopPrank();
        
        // STEP 2: User1 transfers some credits to other users
        vm.startPrank(user1);
        
        // Transfer half of project 0 credits to user2
        uint256 transferAmount1 = projects[0].initialCredits / 2;
        credit.safeTransferFrom(user1, user2, projects[0].id, transferAmount1, "");
        
        // Transfer 1/3 of project 1 credits to user3
        uint256 transferAmount2 = projects[1].initialCredits / 3;
        credit.safeTransferFrom(user1, user3, projects[1].id, transferAmount2, "");
        
        vm.stopPrank();
        
        // Verify balances after transfers
        assertEq(credit.balanceOf(user1, projects[0].id), projects[0].initialCredits - transferAmount1);
        assertEq(credit.balanceOf(user2, projects[0].id), transferAmount1);
        assertEq(credit.balanceOf(user1, projects[1].id), projects[1].initialCredits - transferAmount2);
        assertEq(credit.balanceOf(user3, projects[1].id), transferAmount2);
        
        // STEP 3: Simulate dMRV update - metadata is updated to reflect new measurement
        vm.startPrank(admin);
        
        // Update metadata for project 0 to reflect new verification data
        credit.setTokenURI(projects[0].id, string(abi.encodePacked(projects[0].baseURI, "v2-verified.json")));
        
        vm.stopPrank();
        
        // Verify metadata was updated
        assertEq(credit.uri(projects[0].id), string(abi.encodePacked(projects[0].baseURI, "v2-verified.json")));
        
        // STEP 4: Users retire some credits
        vm.prank(user2);
        uint256 retireAmount1 = transferAmount1 / 2;
        credit.retire(user2, projects[0].id, retireAmount1);
        
        vm.prank(user3);
        uint256 retireAmount2 = transferAmount2;
        credit.retire(user3, projects[1].id, retireAmount2);
        
        // Verify balances after retirement
        assertEq(credit.balanceOf(user2, projects[0].id), transferAmount1 - retireAmount1);
        assertEq(credit.balanceOf(user3, projects[1].id), 0);
        
        // STEP 5: Upgrade to V2 with enhanced features
        DynamicImpactCreditExtendedV2 v2 = new DynamicImpactCreditExtendedV2();
        
        vm.prank(admin);
        IUUPS(address(credit)).upgradeToAndCall(address(v2), "");
        
        // Cast to V2
        DynamicImpactCreditExtendedV2 creditV2 = DynamicImpactCreditExtendedV2(address(credit));
        
        // Verify upgrade was successful
        assertEq(creditV2.VERSION(), 2);
        
        // STEP 6: Use new V2 features
        vm.prank(user1);
        uint256 retireAmount3 = 100;
        creditV2.retire(user1, projects[2].id, retireAmount3);
        
        // Verify V2 specific data
        (uint256 timestamp, uint256 userTotal) = creditV2.getRetirementInfo(projects[2].id, user1);
        assertEq(timestamp, block.timestamp);
        assertEq(userTotal, retireAmount3);
        
        // Confirm old balances are preserved
        assertEq(creditV2.balanceOf(user1, projects[0].id), projects[0].initialCredits - transferAmount1);
        assertEq(creditV2.balanceOf(user2, projects[0].id), transferAmount1 - retireAmount1);
        
        // STEP 7: Mint additional credits with the new implementation
        vm.prank(minter);
        creditV2.mintCredits(user1, 404, 1000, "ipfs://new-project/metadata.json");
        
        assertEq(creditV2.balanceOf(user1, 404), 1000);
    }
    
    // Complex test: Batch operations and approvals
    function testComplex_BatchOperationsAndApprovals() public {
        // STEP 1: Mint multiple token types in a batch
        uint256[] memory ids = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        string[] memory uris = new string[](3);
        
        for (uint i = 0; i < 3; i++) {
            ids[i] = projects[i].id;
            amounts[i] = projects[i].initialCredits;
            uris[i] = string(abi.encodePacked(projects[i].baseURI, "v1.json"));
        }
        
        vm.prank(minter);
        credit.batchMintCredits(user1, ids, amounts, uris);
        
        // Verify all credits were minted
        for (uint i = 0; i < 3; i++) {
            assertEq(credit.balanceOf(user1, ids[i]), amounts[i]);
            assertEq(credit.uri(ids[i]), uris[i]);
        }
        
        // STEP 2: User1 approves user2 to manage all tokens
        vm.prank(user1);
        credit.setApprovalForAll(user2, true);
        
        // STEP 3: User2 transfers from user1 to user3 using approval
        vm.startPrank(user2);
        
        // Transfer half of all projects from user1 to user3
        for (uint i = 0; i < 3; i++) {
            uint256 transferAmount = amounts[i] / 2;
            credit.safeTransferFrom(user1, user3, ids[i], transferAmount, "");
        }
        
        // User2 also retires some credits on behalf of user1
        credit.retire(user1, ids[0], 100);
        
        vm.stopPrank();
        
        // Verify balances after transfers and retirement
        for (uint i = 0; i < 3; i++) {
            uint256 expectedUser1Balance = amounts[i] / 2;
            if (i == 0) expectedUser1Balance -= 100; // Account for retirement
            
            assertEq(credit.balanceOf(user1, ids[i]), expectedUser1Balance);
            assertEq(credit.balanceOf(user3, ids[i]), amounts[i] / 2);
        }
        
        // STEP 4: User1 revokes approval
        vm.prank(user1);
        credit.setApprovalForAll(user2, false);
        
        // STEP 5: User2 attempts to transfer more tokens (should fail)
        vm.prank(user2);
        vm.expectRevert();
        credit.safeTransferFrom(user1, user3, ids[0], 10, "");
    }
} 