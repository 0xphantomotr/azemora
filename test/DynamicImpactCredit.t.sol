// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../src/DynamicImpactCredit.sol";
import "../src/ProjectRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IUUPS {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract DynamicImpactCreditTest is Test {
    DynamicImpactCredit creditImpl;
    DynamicImpactCredit credit;   // proxy cast
    ProjectRegistry registry;

    address admin  = address(0xA11CE);
    address minter = address(0xB01D);
    address user   = address(0xCAFE);
    address other  = address(0xD00D);
    address verifier = address(0xC1E4);

    /* ---------- set-up ---------- */
    function setUp() public {
        vm.startPrank(admin);

        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = ProjectRegistry(address(registryProxy));
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // Deploy Credit Contract
        creditImpl = new DynamicImpactCredit();

        bytes memory creditInitData = abi.encodeCall(
            DynamicImpactCredit.initialize,
            ("ipfs://contract-metadata.json", address(registry))
        );

        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        credit.grantRole(credit.MINTER_ROLE(), minter);
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), admin);

        vm.stopPrank();
    }

    /* ---------- single mint ---------- */
    function testMint() public {
        bytes32 projectId = keccak256("Project-1");
        vm.prank(user);
        registry.registerProject(projectId, "ipfs://project1.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.prank(minter);
        credit.mintCredits(user, projectId, 100, "ipfs://t1.json");

        assertEq(credit.balanceOf(user, uint256(projectId)), 100);
        assertEq(credit.uri(uint256(projectId)), "ipfs://t1.json");
    }

    /* ---------- batch mint ---------- */
    function testBatchMint() public {
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory amounts = new uint256[](2);
        string[] memory uris = new string[](2);

        ids[0] = keccak256("Project-10");
        ids[1] = keccak256("Project-11");
        amounts[0] = 5;
        amounts[1] = 7;
        uris[0] = "ipfs://a.json";
        uris[1] = "ipfs://b.json";

        // Register and activate projects - FIX: separate prank calls for each registration
        vm.prank(user);
        registry.registerProject(ids[0], "p10.json");
        
        vm.prank(user);
        registry.registerProject(ids[1], "p11.json");
        
        vm.startPrank(verifier);
        registry.setProjectStatus(ids[0], ProjectRegistry.ProjectStatus.Active);
        registry.setProjectStatus(ids[1], ProjectRegistry.ProjectStatus.Active);
        vm.stopPrank();

        vm.prank(minter);
        credit.batchMintCredits(user, ids, amounts, uris);

        assertEq(credit.balanceOf(user, uint256(ids[0])), 5);
        assertEq(credit.balanceOf(user, uint256(ids[1])), 7);
        assertEq(credit.uri(uint256(ids[1])), "ipfs://b.json");
    }

    /* ---------- unauthorized mint revert ---------- */
    function testMintNotMinterReverts() public {
        bytes32 projectId = keccak256("Project-2");
        vm.prank(user);
        registry.registerProject(projectId, "p2.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.expectRevert();
        credit.mintCredits(user, projectId, 1, "ipfs://fail.json");
    }

    /* ---------- metadata update ---------- */
    function testSetTokenURI() public {
        bytes32 projectId = keccak256("Project-3");
        vm.prank(user);
        registry.registerProject(projectId, "p3.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        
        vm.startPrank(minter);
        credit.mintCredits(user, projectId, 1, "ipfs://old.json");
        vm.stopPrank();

        vm.prank(admin);
        credit.setTokenURI(projectId, "ipfs://new.json");
        assertEq(credit.uri(uint256(projectId)), "ipfs://new.json");
    }

    /* ---------- retire flow ---------- */
    function testRetire() public {
        bytes32 projectId = keccak256("Project-4");
        vm.prank(user);
        registry.registerProject(projectId, "p4.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        
        vm.prank(minter);
        credit.mintCredits(user, projectId, 10, "ipfs://t.json");

        vm.prank(user);
        credit.retire(user, projectId, 6);

        assertEq(credit.balanceOf(user, uint256(projectId)), 4);
    }

    /* ---------- retire too much reverts ---------- */
    function testRetireTooMuch() public {
        bytes32 projectId = keccak256("Project-5");
        vm.prank(user);
        registry.registerProject(projectId, "p5.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.prank(minter);
        credit.mintCredits(user, projectId, 1, "ipfs://t.json");

        vm.prank(user);
        vm.expectRevert();
        credit.retire(user, projectId, 2);
    }

    /* ---------- re-initialization blocked ---------- */
    function testCannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        credit.initialize("ipfs://again", address(registry));
    }

    /* ---------- upgrade keeps state ---------- */
    function testUpgradeKeepsBalance() public {
        bytes32 projectId = keccak256("Project-7");
        vm.prank(user);
        registry.registerProject(projectId, "p7.json");
        vm.prank(admin);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.prank(minter);
        credit.mintCredits(user, projectId, 42, "ipfs://state.json");

        // deploy V2 with new variable
        DynamicImpactCreditV2 v2 = new DynamicImpactCreditV2();
        
        vm.startPrank(admin);
        // Empty bytes for data since we don't need initialization logic
        IUUPS(address(credit)).upgradeToAndCall(address(v2), "");
        vm.stopPrank();

        // cast back
        DynamicImpactCreditV2 upgraded = DynamicImpactCreditV2(address(credit));

        assertEq(upgraded.balanceOf(user, uint256(projectId)), 42);
        assertEq(upgraded.VERSION(), 2);
    }

    function testRoleAssignment() public view {
        console.log("Admin address:", admin);
        console.log("Admin has DEFAULT_ADMIN_ROLE:", credit.hasRole(credit.DEFAULT_ADMIN_ROLE(), admin));
        console.log("Test contract has DEFAULT_ADMIN_ROLE:", credit.hasRole(credit.DEFAULT_ADMIN_ROLE(), address(this)));
    }
}

/* ---------- dummy V2 impl for upgrade test ---------- */
contract DynamicImpactCreditV2 is DynamicImpactCredit {
    uint256 public constant VERSION = 2;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() DynamicImpactCredit() {
        // constructor is called but implementation remains uninitialized
    }
}