// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/MethodologyRegistry.sol";
import "../mocks/MockVerifierModule.sol";
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
    DMRVManager dmrvManager;
    MockVerifierModule mockModule;
    MethodologyRegistry methodologyRegistry;

    address admin = address(0xA11CE);
    address user = address(0xCAFE);
    address other = address(0xD00D);
    address verifier = address(0xC1E4);
    bytes32 public constant MOCK_MODULE_TYPE = keccak256("mock");

    bytes32 setupProjectId;

    /* ---------- set-up ---------- */
    function setUp() public {
        setupProjectId = keccak256("Project-For-Setup");

        vm.startPrank(admin);

        // Deploy Registry
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(new ProjectRegistry()), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // Deploy Credit Contract
        creditImpl = new DynamicImpactCredit();

        bytes memory creditInitData = abi.encodeCall(
            DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://contract-metadata.json")
        );

        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        // Deploy MethodologyRegistry
        methodologyRegistry = MethodologyRegistry(
            address(
                new ERC1967Proxy(
                    address(new MethodologyRegistry()), abi.encodeCall(MethodologyRegistry.initialize, (admin))
                )
            )
        );

        // Deploy dMRVManager
        DMRVManager dmrvManagerImpl = new DMRVManager();
        bytes memory dmrvInitData =
            abi.encodeCall(DMRVManager.initializeDMRVManager, (address(registry), address(credit)));
        ERC1967Proxy dmrvManagerProxy = new ERC1967Proxy(address(dmrvManagerImpl), dmrvInitData);
        dmrvManager = DMRVManager(address(dmrvManagerProxy));
        dmrvManager.setMethodologyRegistry(address(methodologyRegistry));

        // Deploy Mock Verifier Module and add it to the manager using the new flow
        mockModule = new MockVerifierModule();
        methodologyRegistry.addMethodology(MOCK_MODULE_TYPE, address(mockModule), "ipfs://mock", bytes32(0));
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dmrvManager.registerVerifierModule(MOCK_MODULE_TYPE);

        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dmrvManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(dmrvManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), admin);
        credit.grantRole(credit.PAUSER_ROLE(), admin);

        vm.stopPrank();

        // Register the project here so it exists for all tests that need it.
        vm.prank(user);
        registry.registerProject(setupProjectId, "ipfs://project-for-setup.json");

        vm.prank(verifier);
        registry.setProjectStatus(setupProjectId, IProjectRegistry.ProjectStatus.Active);
    }

    /* ---------- single mint ---------- */
    function testMint() public {
        bytes32 projectId = keccak256("Project-1");
        vm.prank(user);
        registry.registerProject(projectId, "ipfs://project1.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);

        vm.prank(admin);
        dmrvManager.adminSubmitVerification(projectId, 100, "ipfs://t1.json", false);

        assertEq(credit.balanceOf(user, uint256(projectId)), 100);
        assertEq(credit.uri(uint256(projectId)), "ipfs://t1.json");
    }

    /* ---------- batch mint ---------- */
    function testBatchMint() public {
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory amounts = new uint256[](2);
        string[] memory cids = new string[](2);

        ids[0] = keccak256("Project-10");
        ids[1] = keccak256("Project-11");
        amounts[0] = 5;
        amounts[1] = 7;
        cids[0] = "ipfs://a.json";
        cids[1] = "ipfs://b.json";

        // Register and activate projects
        vm.prank(user);
        registry.registerProject(ids[0], "p10.json");

        vm.prank(user);
        registry.registerProject(ids[1], "p11.json");

        vm.startPrank(verifier);
        registry.setProjectStatus(ids[0], IProjectRegistry.ProjectStatus.Active);
        registry.setProjectStatus(ids[1], IProjectRegistry.ProjectStatus.Active);
        vm.stopPrank();

        vm.prank(admin);
        credit.batchMintCredits(user, ids, amounts, cids);
        vm.stopPrank();

        assertEq(credit.balanceOf(user, uint256(ids[0])), 5);
        assertEq(credit.balanceOf(user, uint256(ids[1])), 7);
        assertEq(credit.uri(uint256(ids[1])), "ipfs://b.json");
    }

    /* ---------- unauthorized mint revert ---------- */
    function testMintNotMinterReverts() public {
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", other, credit.DMRV_MANAGER_ROLE()
            )
        );
        vm.prank(other);
        credit.mintCredits(user, setupProjectId, 1, "ipfs://fail.json");
    }

    /* ---------- metadata update ---------- */
    function testUpdateCredentialCID() public {
        string memory oldCID = "ipfs://old.json";
        vm.prank(admin);
        dmrvManager.adminSubmitVerification(setupProjectId, 1, oldCID, false);
        vm.stopPrank();

        vm.prank(admin);
        string memory newCID = "ipfs://new.json";
        credit.updateCredentialCID(setupProjectId, newCID);
        assertEq(credit.uri(uint256(setupProjectId)), newCID);

        string[] memory history = credit.getCredentialCIDHistory(uint256(setupProjectId));
        assertEq(history.length, 2);
        assertEq(history[0], oldCID);
        assertEq(history[1], newCID);
    }

    /* ---------- retire flow ---------- */
    function testRetire() public {
        vm.prank(admin);
        dmrvManager.adminSubmitVerification(setupProjectId, 10, "ipfs://t.json", false);

        vm.prank(user);
        credit.retire(user, setupProjectId, 6);

        assertEq(credit.balanceOf(user, uint256(setupProjectId)), 4);
    }

    /* ---------- retire too much reverts ---------- */
    function testRetireTooMuch() public {
        vm.prank(admin);
        dmrvManager.adminSubmitVerification(setupProjectId, 1, "ipfs://t.json", false);

        vm.prank(user);
        vm.expectRevert();
        credit.retire(user, setupProjectId, 2);
    }

    /* ---------- re-initialization blocked ---------- */
    function testCannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        credit.initializeDynamicImpactCredit(address(registry), "ipfs://again");
    }

    /* ---------- upgrade keeps state ---------- */
    function testUpgradeKeepsBalance() public {
        vm.prank(admin);
        dmrvManager.adminSubmitVerification(setupProjectId, 42, "ipfs://state.json", false);

        // deploy V2 with new variable
        DynamicImpactCreditV2 v2 = new DynamicImpactCreditV2();

        vm.startPrank(admin);
        // Empty bytes for data since we don't need initialization logic
        IUUPS(address(credit)).upgradeToAndCall(address(v2), "");
        vm.stopPrank();

        // cast back
        DynamicImpactCreditV2 upgraded = DynamicImpactCreditV2(address(credit));

        assertEq(upgraded.balanceOf(user, uint256(setupProjectId)), 42);
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
        vm.prank(admin);
        credit.pause();

        bytes4 expectedError = bytes4(keccak256("EnforcedPause()"));
        vm.expectRevert(expectedError);

        // FIX: Have the authorized dMRVManager contract call the paused function directly
        // This correctly isolates the 'whenNotPaused' modifier for the test.
        vm.prank(address(dmrvManager));
        credit.mintCredits(user, setupProjectId, 1, "ipfs://fail-paused.json");
    }

    function test_MintCredits_RevertsForNonActiveProject() public {
        bytes32 inactiveProjectId = keccak256("Project-Inactive-Single-Mint");
        vm.prank(user);
        registry.registerProject(inactiveProjectId, "ipfs://inactive.json");

        vm.prank(admin);
        vm.expectRevert(DMRVManager__ProjectNotActive.selector);
        dmrvManager.adminSubmitVerification(inactiveProjectId, 1, "ipfs://t.json", false);
    }

    function test_Retire_RevertsWhenNotAuthorized() public {
        vm.prank(admin);
        dmrvManager.adminSubmitVerification(setupProjectId, 10, "ipfs://t.json", false);

        // 'other' user, who is not the owner and not approved, tries to retire
        vm.prank(other);
        vm.expectRevert(DynamicImpactCredit__NotAuthorized.selector);
        credit.retire(user, setupProjectId, 5);
    }

    function test_URI_RevertsForNonExistentToken() public {
        bytes4 expectedError = bytes4(keccak256("DynamicImpactCredit__CredentialNotSet()"));
        vm.expectRevert(expectedError);
        credit.uri(99999); // A token that has not been minted
    }

    function test_BatchMint_RevertsOnMismatchedArrays() public {
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory amounts = new uint256[](1); // Mismatched length
        string[] memory cids = new string[](2);

        ids[0] = keccak256("p1");
        ids[1] = keccak256("p2");
        amounts[0] = 1;
        cids[0] = "u1";
        cids[1] = "u2";

        vm.prank(admin);
        vm.expectRevert(DynamicImpactCredit__LengthMismatch.selector);
        credit.batchMintCredits(user, ids, amounts, cids);
    }

    function test_BatchMint_RevertsForNonActiveProject() public {
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory amounts = new uint256[](2);
        string[] memory cids = new string[](2);

        ids[0] = keccak256("inactive-project"); // This project is not active
        ids[1] = keccak256("another-active-one");
        amounts[0] = 5;
        amounts[1] = 7;
        cids[0] = "ipfs://a.json";
        cids[1] = "ipfs://b.json";

        // Register the inactive project
        vm.prank(user);
        registry.registerProject(ids[0], "p10-inactive.json");

        // Activate the second project
        vm.prank(user);
        registry.registerProject(ids[1], "p11.json");
        vm.prank(verifier);
        registry.setProjectStatus(ids[1], IProjectRegistry.ProjectStatus.Active);

        vm.prank(admin);
        vm.expectRevert(DynamicImpactCredit__ProjectNotActive.selector);
        credit.batchMintCredits(user, ids, amounts, cids);
    }
}

/* ---------- dummy V2 impl for upgrade test ---------- */
contract DynamicImpactCreditV2 is UUPSUpgradeable, DynamicImpactCredit {
    uint256 public constant VERSION = 2;

    constructor() DynamicImpactCredit() {}

    function getVersion() external pure returns (uint256) {
        return VERSION;
    }

    function _authorizeUpgrade(address newImplementation) internal override(DynamicImpactCredit, UUPSUpgradeable) {}
}
