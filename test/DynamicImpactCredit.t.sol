// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../src/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IUUPS {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract DynamicImpactCreditTest is Test {
    DynamicImpactCredit impl;
    DynamicImpactCredit credit;   // proxy cast

    address admin  = address(0xA11CE);
    address minter = address(0xB01D);
    address user   = address(0xCAFE);
    address other  = address(0xD00D);

    /* ---------- set-up ---------- */
    function setUp() public {
        vm.startPrank(admin);

        impl = new DynamicImpactCredit();

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

    /* ---------- single mint ---------- */
    function testMint() public {
        vm.prank(minter);
        credit.mintCredits(user, 1, 100, "ipfs://t1.json");

        assertEq(credit.balanceOf(user, 1), 100);
        assertEq(credit.uri(1), "ipfs://t1.json");
    }

    /* ---------- batch mint ---------- */
    function testBatchMint() public {
        // 👇  need `memory`
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        string[] memory uris = new string[](2);

        ids[0] = 10;  ids[1] = 11;
        amounts[0] = 5;  amounts[1] = 7;
        uris[0] = "ipfs://a.json";  uris[1] = "ipfs://b.json";

        vm.prank(minter);
        credit.batchMintCredits(user, ids, amounts, uris);

        assertEq(credit.balanceOf(user, 10), 5);
        assertEq(credit.balanceOf(user, 11), 7);
        assertEq(credit.uri(11), "ipfs://b.json");
    }

    /* ---------- unauthorized mint revert ---------- */
    function testMintNotMinterReverts() public {
        vm.expectRevert();
        credit.mintCredits(user, 2, 1, "ipfs://fail.json");
    }

    /* ---------- metadata update ---------- */
    function testSetTokenURI() public {
        vm.startPrank(minter);
        credit.mintCredits(user, 3, 1, "ipfs://old.json");
        vm.stopPrank();

        vm.prank(admin);
        credit.setTokenURI(3, "ipfs://new.json");
        assertEq(credit.uri(3), "ipfs://new.json");
    }

    /* ---------- retire flow ---------- */
    function testRetire() public {
        vm.prank(minter);
        credit.mintCredits(user, 4, 10, "ipfs://t.json");

        vm.prank(user);
        credit.retire(user, 4, 6);

        assertEq(credit.balanceOf(user, 4), 4);
    }

    /* ---------- retire too much reverts ---------- */
    function testRetireTooMuch() public {
        vm.prank(minter);
        credit.mintCredits(user, 5, 1, "ipfs://t.json");

        vm.prank(user);
        vm.expectRevert();
        credit.retire(user, 5, 2);
    }

    /* ---------- re-initialization blocked ---------- */
    function testCannotReinitialize() public {
        vm.expectRevert();                       // Initializable: contract is already initialized
        credit.initialize("ipfs://again");
    }

    /* ---------- upgrade keeps state ---------- */
    function testUpgradeKeepsBalance() public {
        vm.prank(minter);
        credit.mintCredits(user, 7, 42, "ipfs://state.json");

        // deploy V2 with new variable
        DynamicImpactCreditV2 v2 = new DynamicImpactCreditV2();
        
        vm.startPrank(admin);
        // Empty bytes for data since we don't need initialization logic
        IUUPS(address(credit)).upgradeToAndCall(address(v2), "");
        vm.stopPrank();

        // cast back
        DynamicImpactCreditV2 upgraded = DynamicImpactCreditV2(address(credit));

        assertEq(upgraded.balanceOf(user, 7), 42);
        assertEq(upgraded.VERSION(), 2);
    }

    function testRoleAssignment() public {
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