// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DMRVManagerTest is Test {
    DMRVManager manager;
    ProjectRegistry registry;
    DynamicImpactCredit credit;

    address admin = address(0xA11CE);
    address oracle = address(0x0AC1E);
    address verifier = address(0xC1E4);
    address projectOwner = address(0x044E);

    bytes32 projectId = keccak256("Test Project");

    function setUp() public {
        // Deploy and set up the contract infrastructure
        vm.startPrank(admin);

        // 1. Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInitData = abi.encodeCall(ProjectRegistry.initialize, ());
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = ProjectRegistry(address(registryProxy));
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // 2. Deploy DynamicImpactCredit
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        bytes memory creditInitData =
            abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://contract-metadata.json", address(registry)));
        ERC1967Proxy creditProxy = new ERC1967Proxy(address(creditImpl), creditInitData);
        credit = DynamicImpactCredit(address(creditProxy));

        // 3. Deploy DMRVManager
        DMRVManager managerImpl = new DMRVManager();
        bytes memory managerInitData = abi.encodeCall(DMRVManager.initialize, (address(registry), address(credit)));
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), managerInitData);
        manager = DMRVManager(address(managerProxy));

        // 4. Set up roles
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(manager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(manager));
        manager.grantRole(manager.ORACLE_ROLE(), oracle);

        vm.stopPrank();

        // 5. Register and activate a test project
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");

        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);
    }

    /* ---------- Basic Functionality Tests ---------- */

    function test_Initialization() public view {
        assertEq(address(manager.projectRegistry()), address(registry));
        assertEq(address(manager.creditContract()), address(credit));
        assertTrue(manager.hasRole(manager.ORACLE_ROLE(), oracle));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_RequestVerification() public {
        vm.prank(projectOwner);
        bytes32 requestId = manager.requestVerification(projectId);

        // Verify requestId is not zero
        assertTrue(requestId != bytes32(0));
    }

    /* ---------- Oracle Fulfillment Tests ---------- */

    function test_OracleFulfillment_MintCredits() public {
        // 1. Create a verification request
        vm.prank(projectOwner);
        bytes32 requestId = manager.requestVerification(projectId);

        // 2. Prepare oracle data for minting 100 credits
        uint256 creditAmount = 100;
        string memory metadataURI = "ipfs://new-verification.json";
        bool updateMetadataOnly = false;
        bytes32 signature = keccak256(abi.encodePacked("test-signature"));

        // 3. Encode the data according to our expected format
        bytes memory data = abi.encode(creditAmount, updateMetadataOnly, signature, metadataURI);

        // 4. Oracle fulfills the verification
        vm.prank(oracle);
        manager.fulfillVerification(requestId, data);

        // 5. Check that credits were minted to project owner
        assertEq(credit.balanceOf(projectOwner, uint256(projectId)), 100);
        assertEq(credit.uri(uint256(projectId)), metadataURI);
    }

    function test_OracleFulfillment_UpdateMetadataOnly() public {
        // 1. First mint some initial credits directly instead of calling the other test
        vm.prank(projectOwner);
        bytes32 initialRequestId = manager.requestVerification(projectId);

        // Set up initial minting data
        bytes memory initialData = abi.encode(
            uint256(100), // creditAmount
            false, // updateMetadataOnly
            bytes32(0), // signature
            "ipfs://initial.json" // metadataURI
        );

        vm.prank(oracle);
        manager.fulfillVerification(initialRequestId, initialData);

        uint256 initialBalance = credit.balanceOf(projectOwner, uint256(projectId));

        // 2. Create a new verification request
        vm.prank(projectOwner);
        bytes32 requestId = manager.requestVerification(projectId);

        // 3. Prepare oracle data for updating metadata only
        uint256 creditAmount = 0; // No new credits
        string memory metadataURI = "ipfs://updated-verification.json";
        bool updateMetadataOnly = true;
        bytes32 signature = keccak256(abi.encodePacked("test-signature-2"));

        // 4. Encode the data
        bytes memory data = abi.encode(creditAmount, updateMetadataOnly, signature, metadataURI);

        // 5. Oracle fulfills the verification
        vm.prank(oracle);
        manager.fulfillVerification(requestId, data);

        // 6. Check that only metadata was updated (balance unchanged)
        assertEq(credit.balanceOf(projectOwner, uint256(projectId)), initialBalance);
        assertEq(credit.uri(uint256(projectId)), metadataURI);
    }

    /* ---------- Admin Functions ---------- */

    function test_AdminSetVerification() public {
        // Admin can directly set verification without oracle
        vm.prank(admin);
        manager.adminSetVerification(projectId, 50, "ipfs://admin-set.json", false);

        // Check credits were minted
        assertEq(credit.balanceOf(projectOwner, uint256(projectId)), 50);
        assertEq(credit.uri(uint256(projectId)), "ipfs://admin-set.json");
    }

    /* ---------- Error Cases ---------- */

    function test_RequestVerification_RequiresActiveProject() public {
        // Create an inactive project
        bytes32 inactiveId = keccak256("Inactive Project");
        vm.prank(projectOwner);
        registry.registerProject(inactiveId, "ipfs://inactive.json");
        // Note: We don't activate it

        // Attempt to request verification should fail
        vm.prank(projectOwner);
        vm.expectRevert("DMRVManager: Project not active");
        manager.requestVerification(inactiveId);
    }

    function test_FulfillVerification_OnlyOracle() public {
        // 1. Create a request
        vm.prank(projectOwner);
        bytes32 requestId = manager.requestVerification(projectId);

        // 2. Prepare some data
        bytes memory data = abi.encode(uint256(100), false, bytes32(0), "ipfs://test.json");

        // 3. Attempt to fulfill from non-oracle account
        vm.prank(projectOwner);
        vm.expectRevert(); // Will revert due to AccessControl
        manager.fulfillVerification(requestId, data);
    }

    function test_FulfillVerification_CannotFulfillTwice() public {
        // 1. Create a request
        vm.prank(projectOwner);
        bytes32 requestId = manager.requestVerification(projectId);

        // 2. Prepare some data
        bytes memory data = abi.encode(uint256(100), false, bytes32(0), "ipfs://test.json");

        // 3. Oracle fulfills the verification
        vm.prank(oracle);
        manager.fulfillVerification(requestId, data);

        // 4. Try to fulfill again should fail
        vm.prank(oracle);
        vm.expectRevert("DMRVManager: Request already fulfilled");
        manager.fulfillVerification(requestId, data);
    }

    /* ---------- Pausable Tests ---------- */

    function test_PauseAndUnpause() public {
        bytes32 pauserRole = manager.PAUSER_ROLE();

        vm.startPrank(admin);
        // Admin has pauser role by default from setUp
        manager.pause();
        assertTrue(manager.paused());
        manager.unpause();
        assertFalse(manager.paused());
        vm.stopPrank();

        // Non-pauser cannot pause
        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), projectOwner, pauserRole));
        manager.pause();
    }

    function test_RevertsWhenPaused() public {
        vm.prank(admin);
        manager.pause();

        bytes4 expectedRevert = bytes4(keccak256("EnforcedPause()"));

        vm.prank(projectOwner);
        vm.expectRevert(expectedRevert);
        manager.requestVerification(projectId);

        vm.prank(oracle);
        bytes memory data = abi.encode(1, false, bytes32(0), "ipfs://fail.json");
        vm.expectRevert(expectedRevert);
        manager.fulfillVerification(bytes32(0), data);

        vm.prank(admin);
        vm.expectRevert(expectedRevert);
        manager.adminSetVerification(projectId, 1, "ipfs://fail.json", false);
    }
}
