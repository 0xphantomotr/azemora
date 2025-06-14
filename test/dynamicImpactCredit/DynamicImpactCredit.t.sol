// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IUUPS {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract DynamicImpactCreditTest is Test {
    DynamicImpactCredit creditImpl;
    DynamicImpactCredit credit; // proxy cast
    ProjectRegistry registry;

    address admin = address(0xA11CE);
    address dmrvManager = address(0xB01D);
    address user = address(0xCAFE);
    address other = address(0xD00D);
    address verifier = address(0xC1E4);

    bytes32 setupProjectId;

    /* ---------- set-up ---------- */
    function setUp() public {
        setupProjectId = keccak256("Project-For-Setup");

        vm.startPrank(admin);

        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = ProjectRegistry(address(registryProxy));
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // Deploy Credit Contract
        creditImpl = new DynamicImpactCredit();

        bytes memory creditInitData =
            abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://contract-metadata.json", address(registry)));

        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        credit.grantRole(credit.DMRV_MANAGER_ROLE(), dmrvManager);
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), admin);

        vm.stopPrank();

        // Register the project here so it exists for all tests that need it.
        vm.prank(user);
        registry.registerProject(setupProjectId, "ipfs://project-for-setup.json");
    }

    /* ---------- single mint ---------- */
    function testMint() public {
        bytes32 projectId = keccak256("Project-1");
        vm.prank(user);
        registry.registerProject(projectId, "ipfs://project1.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.prank(dmrvManager);
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

        vm.prank(dmrvManager);
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
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", other, credit.DMRV_MANAGER_ROLE()
            )
        );
        vm.prank(other);
        credit.mintCredits(user, projectId, 1, "ipfs://fail.json");
    }

    /* ---------- metadata update ---------- */
    function testSetTokenURI() public {
        bytes32 projectId = keccak256("Project-3");
        vm.prank(user);
        registry.registerProject(projectId, "p3.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        string memory oldURI = "ipfs://old.json";
        vm.startPrank(dmrvManager);
        credit.mintCredits(user, projectId, 1, oldURI);
        vm.stopPrank();

        vm.prank(admin);
        string memory newURI = "ipfs://new.json";
        credit.setTokenURI(projectId, newURI);
        assertEq(credit.uri(uint256(projectId)), newURI);

        string[] memory history = credit.getTokenURIHistory(uint256(projectId));
        assertEq(history.length, 2);
        assertEq(history[0], oldURI);
        assertEq(history[1], newURI);
    }

    /* ---------- retire flow ---------- */
    function testRetire() public {
        bytes32 projectId = keccak256("Project-4");
        vm.prank(user);
        registry.registerProject(projectId, "p4.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.prank(dmrvManager);
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
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.prank(dmrvManager);
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
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        vm.prank(dmrvManager);
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

    /* ---------- Pausable Tests ---------- */

    function test_PauseAndUnpause() public {
        bytes32 pauserRole = credit.PAUSER_ROLE();

        vm.startPrank(admin);
        // Admin has pauser role by default from setUp
        credit.pause();
        assertTrue(credit.paused());
        credit.unpause();
        assertFalse(credit.paused());
        vm.stopPrank();

        // Non-pauser cannot pause
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), other, pauserRole
            )
        );
        credit.pause();
    }

    function test_RevertsWhenPaused() public {
        bytes32 projectId = keccak256("Project-Pausable");
        vm.prank(user);
        registry.registerProject(projectId, "p-pausable.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
        vm.prank(dmrvManager);
        credit.mintCredits(user, projectId, 100, "ipfs://pausable.json");

        // Pause the contract
        vm.prank(admin);
        credit.pause();

        // Check key functions revert
        bytes4 expectedRevert = bytes4(keccak256("EnforcedPause()"));

        vm.prank(dmrvManager);
        vm.expectRevert(expectedRevert);
        credit.mintCredits(user, projectId, 1, "ipfs://fail.json");

        vm.prank(admin);
        vm.expectRevert(expectedRevert);
        credit.setTokenURI(projectId, "ipfs://fail.json");

        vm.prank(user);
        vm.expectRevert(expectedRevert);
        credit.retire(user, projectId, 1);
    }

    function test_MintCredits_RevertsForNonActiveProject() public {
        // The setupProjectId from setUp is registered but not yet active
        vm.prank(dmrvManager);
        vm.expectRevert("NOT_ACTIVE");
        credit.mintCredits(user, setupProjectId, 100, "ipfs://fail.json");
    }

    function test_Retire_RevertsWhenNotAuthorized() public {
        // Activate project and mint some credits first
        vm.prank(verifier);
        registry.setProjectStatus(setupProjectId, ProjectRegistry.ProjectStatus.Active);
        vm.prank(dmrvManager);
        credit.mintCredits(user, setupProjectId, 100, "ipfs://mint.json");

        // 'other' user tries to retire 'user's tokens
        vm.prank(other);
        vm.expectRevert("NOT_AUTHORIZED");
        credit.retire(user, setupProjectId, 50);
    }

    function test_URI_RevertsForNonExistentToken() public {
        vm.expectRevert("URI not set for token");
        credit.uri(uint256(keccak256("non-existent-token")));
    }

    function test_BatchMint_RevertsOnMismatchedArrays() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = setupProjectId;
        uint256[] memory amounts = new uint256[](2); // Mismatched length
        amounts[0] = 100;
        amounts[1] = 200;
        string[] memory uris = new string[](1);
        uris[0] = "a";

        vm.prank(dmrvManager);
        vm.expectRevert("LENGTH_MISMATCH");
        credit.batchMintCredits(user, ids, amounts, uris);
    }

    function test_BatchMint_RevertsForNonActiveProject() public {
        // The setupProjectId from setUp is registered but not yet active
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = setupProjectId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        string[] memory uris = new string[](1);
        uris[0] = "a";

        vm.prank(dmrvManager);
        vm.expectRevert("DIC: PROJECT_NOT_ACTIVE");
        credit.batchMintCredits(user, ids, amounts, uris);
    }
}

/* ---------- dummy V2 impl for upgrade test ---------- */
contract DynamicImpactCreditV2 is DynamicImpactCredit {
    uint256 public constant VERSION = 2;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // constructor is called but implementation remains uninitialized
    }
}
