// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DMRVManagerFuzzTest is Test {
    DMRVManager manager;
    ProjectRegistry registry;
    DynamicImpactCredit credit;

    address admin = address(0xA11CE);
    address oracle = address(0x0AC1E);
    address verifier = address(0xC1E4);
    address projectOwner = address(0x044E);

    bytes32 projectId = keccak256("Fuzz Test Project");

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
                    address(new DynamicImpactCredit(address(registry))),
                    abi.encodeCall(DynamicImpactCredit.initialize, ("uri"))
                )
            )
        );

        // 3. Deploy DMRVManager
        DMRVManager managerImpl = new DMRVManager(address(registry), address(credit));
        manager =
            DMRVManager(address(new ERC1967Proxy(address(managerImpl), abi.encodeCall(DMRVManager.initialize, ()))));

        // 4. Set up roles
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(manager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(manager));
        manager.grantRole(manager.ORACLE_ROLE(), oracle);

        vm.stopPrank();

        // 5. Register and activate a test project for fuzzing
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://initial.json");

        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        // 6. Set an initial verification to establish a base URI history
        vm.prank(admin);
        manager.adminSubmitVerification(projectId, 1, "ipfs://initial.json", false);
    }

    function testFuzz_FulfillVerification(
        uint256 creditAmount,
        bool updateMetadataOnly,
        bytes32 signature,
        string calldata metadataURI
    ) public {
        // Bound the amount to prevent absolutely massive numbers that trigger edge cases
        // Uint64.max (18.4 quintillion) is a practical but still very large limit
        uint64 maxAmount = type(uint64).max;
        creditAmount = bound(creditAmount, 0, maxAmount);

        // Skip empty strings or strings with ASCII control characters
        vm.assume(bytes(metadataURI).length > 0);

        // --- Setup State ---
        // 1. Create a fresh verification request for each fuzz run
        vm.prank(projectOwner);
        bytes32 requestId = manager.requestVerification(projectId);

        // 2. Capture initial state
        uint256 initialBalance = credit.balanceOf(projectOwner, uint256(projectId));
        string[] memory initialHistory = credit.getTokenURIHistory(uint256(projectId));
        uint256 initialHistoryLength = initialHistory.length;

        // --- Execute Action ---
        // 3. Prepare oracle data and fulfill the request
        bytes memory data = abi.encode(creditAmount, updateMetadataOnly, signature, metadataURI);

        vm.prank(oracle);
        manager.fulfillVerification(requestId, data);

        // --- Assert Final State ---
        // 4. Verify the state changes match the inputs
        if (updateMetadataOnly) {
            // Balance should be unchanged
            assertEq(
                credit.balanceOf(projectOwner, uint256(projectId)),
                initialBalance,
                "Balance should not change on metadata update"
            );

            // Metadata should be updated and history grown by 1
            assertEq(credit.uri(uint256(projectId)), metadataURI, "URI should be updated");
            string[] memory finalHistory = credit.getTokenURIHistory(uint256(projectId));
            assertEq(finalHistory.length, initialHistoryLength + 1, "URI history should grow by 1");
            assertEq(finalHistory[finalHistory.length - 1], metadataURI, "New URI should be last in history");
        } else {
            // Balance should increase by the credit amount
            assertEq(
                credit.balanceOf(projectOwner, uint256(projectId)),
                initialBalance + creditAmount,
                "Balance should increase on mint"
            );

            // Metadata should be updated if credits were minted
            if (creditAmount > 0) {
                assertEq(credit.uri(uint256(projectId)), metadataURI, "URI should be updated on mint");
                string[] memory finalHistory = credit.getTokenURIHistory(uint256(projectId));
                assertEq(finalHistory.length, initialHistoryLength + 1, "URI history should grow by 1 on mint");
            } else {
                // If amount is 0 and not update-only, nothing should change
                assertEq(
                    credit.uri(uint256(projectId)),
                    initialHistory[initialHistory.length - 1],
                    "URI should not change if amount is 0"
                );
            }
        }
    }
}
