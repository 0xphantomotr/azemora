// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/ProjectRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/core/MethodologyRegistry.sol";
import "../mocks/MockVerifierModule.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DMRVManagerFuzzTest is Test {
    DMRVManager dMRVManager;
    ProjectRegistry registry;
    DynamicImpactCredit credit;
    MockVerifierModule mockModule;
    MethodologyRegistry methodologyRegistry;

    address admin = address(0xA11CE);
    address projectOwner = address(0x044E);
    address verifier = address(0xC1E4);

    bytes32 projectId = keccak256("Fuzz Test Project");
    bytes32 public constant MOCK_MODULE_TYPE = keccak256("mock");

    function setUp() public {
        // Deploy and set up the contract infrastructure
        vm.startPrank(admin);

        // 1. Deploy Registry
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(new ProjectRegistry()), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // 2. Deploy DynamicImpactCredit
        credit = DynamicImpactCredit(
            address(
                new ERC1967Proxy(
                    address(new DynamicImpactCredit()),
                    abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "uri"))
                )
            )
        );

        // 3. Deploy MethodologyRegistry
        MethodologyRegistry methodologyRegistryImpl = new MethodologyRegistry();
        bytes memory methodologyInitData = abi.encodeCall(MethodologyRegistry.initialize, (admin));
        methodologyRegistry =
            MethodologyRegistry(address(new ERC1967Proxy(address(methodologyRegistryImpl), methodologyInitData)));

        // 4. Deploy DMRVManager
        DMRVManager dMRVManagerImpl = new DMRVManager();
        bytes memory dMRVManagerInitData =
            abi.encodeCall(DMRVManager.initializeDMRVManager, (address(registry), address(credit)));
        dMRVManager = DMRVManager(address(new ERC1967Proxy(address(dMRVManagerImpl), dMRVManagerInitData)));
        dMRVManager.setMethodologyRegistry(address(methodologyRegistry));

        // 5. Deploy and register mock module via the new flow
        mockModule = new MockVerifierModule();
        methodologyRegistry.addMethodology(
            MOCK_MODULE_TYPE,
            address(mockModule),
            "ipfs://mock-methodology",
            bytes32(0) // schemaHash - providing a null value for the test
        );
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.registerVerifierModule(MOCK_MODULE_TYPE);

        // 6. Set up roles
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(dMRVManager));

        vm.stopPrank();

        // 7. Register and activate a test project for fuzzing
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");

        vm.prank(verifier);
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
    }

    function testFuzz_FulfillVerification(
        uint96 creditAmount, // Bounded to prevent overflow in some calculations
        bool updateMetadataOnly,
        bytes32 signature, // Unused in this test but kept for signature consistency
        string calldata metadataURI
    ) public {
        // Skip empty strings or strings that are too long to be practical for URIs
        vm.assume(bytes(metadataURI).length > 0 && bytes(metadataURI).length < 200);

        // --- Setup State ---
        // 1. Create a fresh verification request for each fuzz run
        vm.prank(projectOwner);
        bytes32 claimId = keccak256(abi.encodePacked(creditAmount, updateMetadataOnly, metadataURI, block.timestamp));
        dMRVManager.requestVerification(projectId, claimId, "ipfs://fuzz-evidence", MOCK_MODULE_TYPE);

        // 2. Capture initial state
        uint256 tokenId = uint256(projectId);
        uint256 initialBalance = credit.balanceOf(projectOwner, tokenId);
        uint256 initialHistoryLength = credit.getTokenURIHistory(tokenId).length;

        // --- Execute Action ---
        // 3. Prepare module data and fulfill the request
        bytes memory data = abi.encode(creditAmount, updateMetadataOnly, signature, metadataURI);

        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(projectId, claimId, data);

        // --- Assert Final State ---
        // 4. Verify the state changes match the inputs
        if (updateMetadataOnly) {
            // Balance should be unchanged
            assertEq(
                credit.balanceOf(projectOwner, tokenId), initialBalance, "Balance should not change on metadata update"
            );

            // Metadata should be updated and history grown by 1
            string[] memory finalHistory = credit.getTokenURIHistory(tokenId);
            assertEq(finalHistory.length, initialHistoryLength + 1, "URI history should grow by 1");
            assertEq(finalHistory[finalHistory.length - 1], metadataURI, "New URI should be last in history");
        } else {
            // Balance should increase by the credit amount
            assertEq(
                credit.balanceOf(projectOwner, tokenId),
                initialBalance + creditAmount,
                "Balance should increase on mint"
            );

            // Metadata should be updated if credits were minted
            if (creditAmount > 0) {
                string[] memory finalHistory = credit.getTokenURIHistory(tokenId);
                assertEq(finalHistory.length, initialHistoryLength + 1, "URI history should grow by 1 on mint");
                assertEq(finalHistory[finalHistory.length - 1], metadataURI, "URI should be updated on mint");
            } else {
                // If amount is 0 and not update-only, nothing should change, history length is the same.
                string[] memory finalHistory = credit.getTokenURIHistory(tokenId);
                assertEq(finalHistory.length, initialHistoryLength, "URI history should not change if amount is 0");
            }
        }
    }
}
