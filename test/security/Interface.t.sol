// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/token/AzemoraToken.sol";

// Minimal local interface for casting in the AzemoraToken test.
interface IERC165ForTest {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// Using hardcoded, standard interface IDs to avoid compiler conflicts.
contract InterfaceComplianceTest is Test {
    // --- Contracts ---
    ProjectRegistry public registry;
    DMRVManager public dmrvManager;
    DynamicImpactCredit public credit;
    Marketplace public marketplace;
    AzemoraToken public token;

    // --- Standard Interface IDs ---
    bytes4 internal constant IID_ERC165 = 0x01ffc9a7;
    bytes4 internal constant IID_ACCESS_CONTROL = 0x7965db0b;
    bytes4 internal constant IID_ERC1155 = 0xd9b67a26;
    bytes4 internal constant IID_ERC1155_RECEIVER = 0x4e2312e0;

    // --- Custom Interface ID ---
    bytes4 internal iProjectRegistry = type(IProjectRegistry).interfaceId;

    function setUp() public {
        // We only need to deploy the implementations, as we are just checking interface support
        // which does not depend on state or initialization. We DO NOT initialize them.
        registry = new ProjectRegistry();
        dmrvManager = new DMRVManager(address(0x1), address(0x2)); // Pass non-zero dummy addresses
        credit = new DynamicImpactCredit(address(0x3));
        marketplace = new Marketplace();
        token = new AzemoraToken();
    }

    function test_ProjectRegistry_Interfaces() public view {
        assertTrue(registry.supportsInterface(IID_ERC165), "Registry should support IERC165");
        assertTrue(registry.supportsInterface(IID_ACCESS_CONTROL), "Registry should support IAccessControl");
        assertTrue(registry.supportsInterface(iProjectRegistry), "Registry should support IProjectRegistry");
        assertFalse(registry.supportsInterface(IID_ERC1155), "Registry should NOT support IERC1155");
    }

    function test_DMRVManager_Interfaces() public view {
        assertTrue(dmrvManager.supportsInterface(IID_ERC165), "DMRVManager should support IERC165");
        assertTrue(dmrvManager.supportsInterface(IID_ACCESS_CONTROL), "DMRVManager should support IAccessControl");
        assertFalse(dmrvManager.supportsInterface(iProjectRegistry), "DMRVManager should NOT support IProjectRegistry");
    }

    function test_DynamicImpactCredit_Interfaces() public view {
        assertTrue(credit.supportsInterface(IID_ERC165), "Credit should support IERC165");
        assertTrue(credit.supportsInterface(IID_ACCESS_CONTROL), "Credit should support IAccessControl");
        assertTrue(credit.supportsInterface(IID_ERC1155), "Credit should support IERC1155");
        assertFalse(credit.supportsInterface(IID_ERC1155_RECEIVER), "Credit should NOT support IERC1155Receiver");
    }

    function test_Marketplace_Interfaces() public view {
        assertTrue(marketplace.supportsInterface(IID_ERC165), "Marketplace should support IERC165");
        assertTrue(marketplace.supportsInterface(IID_ACCESS_CONTROL), "Marketplace should support IAccessControl");
        assertTrue(marketplace.supportsInterface(IID_ERC1155_RECEIVER), "Marketplace should support IERC1155Receiver");
        assertFalse(marketplace.supportsInterface(IID_ERC1155), "Marketplace should NOT support IERC1155");
    }

    function test_AzemoraToken_Interfaces() public view {
        // UUPSUpgradeable contracts inherit from ERC1967 and will return true for supportsInterface(ERC165).
        assertTrue(
            IERC165ForTest(address(token)).supportsInterface(IID_ERC165), "Token (as UUPS) SHOULD support IERC165"
        );
        // The token uses AccessControl, so this should be true.
        assertTrue(
            IERC165ForTest(address(token)).supportsInterface(IID_ACCESS_CONTROL), "Token SHOULD support IAccessControl"
        );
    }
}
