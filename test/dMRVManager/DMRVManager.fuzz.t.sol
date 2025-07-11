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
        bytes memory dMRVManagerInitData = abi.encodeCall(
            DMRVManager.initializeDMRVManager, (address(registry), address(credit), address(methodologyRegistry))
        );
        dMRVManager = DMRVManager(address(new ERC1967Proxy(address(dMRVManagerImpl), dMRVManagerInitData)));

        // 5. Deploy and register mock module via the new flow
        mockModule = new MockVerifierModule();
        methodologyRegistry.addMethodology(
            MOCK_MODULE_TYPE,
            address(mockModule),
            "ipfs://mock-methodology",
            bytes32(0) // schemaHash - providing a null value for the test
        );
        methodologyRegistry.approveMethodology(MOCK_MODULE_TYPE);
        dMRVManager.addVerifierModule(MOCK_MODULE_TYPE);

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
        uint8 quantitativeOutcome, // Represents a percentage, 0-100
        string calldata credentialCID
    ) public {
        // --- Assumptions ---
        vm.assume(quantitativeOutcome <= 100); // Quantitative outcome is a percentage.
        vm.assume(bytes(credentialCID).length > 0 && bytes(credentialCID).length < 200);

        // --- Setup State ---
        // 1. Create a fresh verification request for each fuzz run
        uint256 requestedAmount = 100e18; // This is the fixed request amount for the test.
        bytes32 claimId = keccak256(abi.encodePacked(quantitativeOutcome, credentialCID, block.timestamp));
        vm.prank(projectOwner);
        dMRVManager.requestVerification(projectId, claimId, "ipfs://fuzz-evidence", requestedAmount, MOCK_MODULE_TYPE);

        // 2. Calculate expected outcome
        uint256 expectedMintAmount = (requestedAmount * quantitativeOutcome) / 100;

        // 3. Capture initial state
        uint256 tokenId = uint256(projectId);
        uint256 initialBalance = credit.balanceOf(projectOwner, tokenId);
        uint256 initialHistoryLength = credit.getCredentialCIDHistory(tokenId).length;

        // --- Execute Action ---
        // 4. Prepare module data and fulfill the request
        bytes memory data = abi.encode(uint256(quantitativeOutcome), false, bytes32(0), credentialCID);

        vm.prank(address(mockModule));
        dMRVManager.fulfillVerification(projectId, claimId, data);

        // --- Assert Final State ---
        // 5. Verify the state changes match the inputs
        assertEq(
            credit.balanceOf(projectOwner, tokenId),
            initialBalance + expectedMintAmount,
            "Balance should increase by the calculated proportional amount"
        );

        // Metadata should be updated if credits were minted
        if (expectedMintAmount > 0) {
            string[] memory finalHistory = credit.getCredentialCIDHistory(tokenId);
            assertEq(finalHistory.length, initialHistoryLength + 1, "CID history should grow by 1 on mint");
            assertEq(finalHistory[finalHistory.length - 1], credentialCID, "CID should be updated on mint");
        } else {
            // If amount is 0, nothing should change, history length is the same.
            string[] memory finalHistory = credit.getCredentialCIDHistory(tokenId);
            assertEq(finalHistory.length, initialHistoryLength, "CID history should not change if amount is 0");
        }
    }
}
