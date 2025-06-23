// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DynamicImpactCreditFuzzTest is Test {
    DynamicImpactCredit credit;
    ProjectRegistry registry;
    address admin = address(0xA11CE);
    address dmrvManager = address(0xB01D);
    address user = address(0xCAFE);
    address verifier = address(0xC1E4);

    function setUp() public {
        vm.startPrank(admin);
        // Deploy Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        registry = ProjectRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProjectRegistry.initialize, ())))
        );
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // Deploy Credit Contract
        DynamicImpactCredit impl = new DynamicImpactCredit();

        bytes memory initData = abi.encodeCall(
            DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "ipfs://contract-metadata.json")
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        credit = DynamicImpactCredit(address(proxy));

        credit.grantRole(credit.DMRV_MANAGER_ROLE(), dmrvManager);
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), admin);
        vm.stopPrank();
    }

    // Fuzz test: Batch mint with varying array lengths and contents
    function testFuzz_BatchMintArrays(uint8 arraySize, uint64 seed) public {
        // Bound arraySize to avoid extreme values
        arraySize = uint8(bound(arraySize, 1, 20));

        // Create arrays of proper length
        bytes32[] memory ids = new bytes32[](arraySize);
        uint256[] memory amounts = new uint256[](arraySize);
        string[] memory uris = new string[](arraySize);

        // Generate deterministic but varied data based on seed
        for (uint8 i = 0; i < arraySize; i++) {
            // Ensure unique IDs by using the index
            ids[i] = keccak256(abi.encode(seed, i + 1));
            amounts[i] = uint256(keccak256(abi.encode(seed, "amount", i))) % 1000 + 1;
            uris[i] = string(
                abi.encodePacked("ipfs://", vm.toString(uint256(keccak256(abi.encode(seed, "uri", i))) % 1000000))
            );
            // Register and activate project
            vm.prank(user);
            registry.registerProject(ids[i], "meta.json");
            vm.prank(verifier);
            registry.setProjectStatus(ids[i], ProjectRegistry.ProjectStatus.Active);
        }

        vm.prank(dmrvManager);
        credit.batchMintCredits(user, ids, amounts, uris);

        // Verify all tokens were minted with correct amounts and URIs
        for (uint8 i = 0; i < arraySize; i++) {
            assertEq(credit.balanceOf(user, uint256(ids[i])), amounts[i], "Balance mismatch for token ID");
            assertEq(credit.uri(uint256(ids[i])), uris[i], "URI mismatch for token ID");
        }
    }

    // Fuzz test: Retirement with random amounts
    function testFuzz_Retire(uint256 seed, uint256 mintAmount, uint256 retireAmount) public {
        bytes32 projectId = keccak256(abi.encode(seed));
        // Constrain values to reasonable ranges
        mintAmount = bound(mintAmount, 1, 1000000);
        retireAmount = bound(retireAmount, 1, mintAmount);

        // Register and activate project
        vm.prank(user);
        registry.registerProject(projectId, "meta.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        // Mint the tokens
        vm.prank(dmrvManager);
        credit.mintCredits(user, projectId, mintAmount, string(abi.encodePacked("ipfs://token", vm.toString(seed))));

        // Retire some tokens
        vm.prank(user);
        credit.retire(user, projectId, retireAmount);

        // Verify the remaining balance
        assertEq(credit.balanceOf(user, uint256(projectId)), mintAmount - retireAmount);
    }

    // Fuzz test: URI updates with random strings
    function testFuzz_URIUpdates(uint256 seed, string calldata initialURI, string calldata updatedURI) public {
        bytes32 projectId = keccak256(abi.encode(seed));

        // Register and activate project
        vm.prank(user);
        registry.registerProject(projectId, "meta.json");
        vm.prank(verifier);
        registry.setProjectStatus(projectId, ProjectRegistry.ProjectStatus.Active);

        // Mint with initial URI
        vm.prank(dmrvManager);
        credit.mintCredits(user, projectId, 100, initialURI);

        // Update URI
        vm.prank(admin);
        credit.setTokenURI(projectId, updatedURI);

        // Verify the URI was updated
        assertEq(credit.uri(uint256(projectId)), updatedURI);

        // Verify history
        string[] memory history = credit.getTokenURIHistory(uint256(projectId));
        assertEq(history.length, 2, "History length should be 2");
        assertEq(history[0], initialURI, "Initial URI mismatch in history");
        assertEq(history[1], updatedURI, "Updated URI mismatch in history");
    }
}
