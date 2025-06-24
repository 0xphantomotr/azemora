// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Import all necessary contracts
import "../../src/depin/DePINVerifier.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/interfaces/IVerifierModule.sol";
import "../../src/core/ProjectRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../mocks/MockDePINOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DePINVerifierTest is Test {
    // --- Contracts ---
    ProjectRegistry internal registry;
    DynamicImpactCredit internal credit;
    DMRVManager internal dMRVManager;
    DePINVerifier internal depinVerifier;
    MockDePINOracle internal mockOracle;

    // --- Actors ---
    address internal projectOwner = makeAddr("projectOwner");
    address internal randomUser = makeAddr("randomUser");

    // --- Constants ---
    bytes32 internal constant DEPIN_MODULE_ID = keccak256("DEPIN_VERIFIER_V1");
    bytes32 internal projectId = keccak256("Test DePIN Project");
    bytes32 internal claimId = keccak256("Test Claim 1");
    bytes32 internal sensorId = keccak256("SENSOR-001");

    function setUp() public {
        // --- Deploy Implementations ---
        // These are the raw logic contracts. We will not interact with them directly.
        DePINVerifier depinVerifierImpl = new DePINVerifier();
        DMRVManager dMRVManagerImpl = new DMRVManager();
        ProjectRegistry registryImpl = new ProjectRegistry();
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();

        // --- Prepare Initialization Calldata ---
        // This is the data that will be passed to the proxies to call the real initialize functions.
        bytes memory registryInitData = abi.encodeWithSelector(registryImpl.initialize.selector);

        // We need the proxy addresses *before* we can create the calldata for the other contracts.
        // We can pre-compute them because proxy addresses are deterministic based on deployer and nonce.
        address registryProxyAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address creditProxyAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        bytes memory creditInitData = abi.encodeWithSelector(
            creditImpl.initializeDynamicImpactCredit.selector, registryProxyAddress, "ipfs://contract-meta"
        );
        bytes memory dMRVManagerInitData = abi.encodeWithSelector(
            dMRVManagerImpl.initializeDMRVManager.selector, registryProxyAddress, creditProxyAddress
        );

        // --- Deploy Proxies ---
        // We deploy proxies pointing to our implementations and initialize them in the same transaction.
        registry = ProjectRegistry(payable(new ERC1967Proxy(address(registryImpl), registryInitData)));
        credit = DynamicImpactCredit(payable(new ERC1967Proxy(address(creditImpl), creditInitData)));
        dMRVManager = DMRVManager(payable(new ERC1967Proxy(address(dMRVManagerImpl), dMRVManagerInitData)));

        // --- Deploy Non-Upgradeable Contracts ---
        mockOracle = new MockDePINOracle();

        // The DePINVerifier is also upgradeable, so we'll use a proxy for it as well.
        bytes memory depinVerifierInitData =
            abi.encodeWithSelector(depinVerifierImpl.initialize.selector, address(mockOracle), address(this));
        depinVerifier = DePINVerifier(payable(new ERC1967Proxy(address(depinVerifierImpl), depinVerifierInitData)));

        // --- Configure System Dependencies & Roles ---
        // Now we interact with the contracts *through their proxy addresses*.

        // 1. Link the verifier to the manager.
        depinVerifier.setDMRVManager(address(dMRVManager));

        // 2. Grant the dMRVManager's MODULE_ADMIN_ROLE to the test contract (`this`).
        dMRVManager.grantRole(dMRVManager.MODULE_ADMIN_ROLE(), address(this));
        dMRVManager.registerVerifierModule(DEPIN_MODULE_ID, address(depinVerifier));

        // 3. Grant the DynamicImpactCredit contract's roles to the dMRVManager.
        // This allows the manager to mint credits and update token URIs on behalf of verifiers.
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), address(dMRVManager));
        credit.grantRole(credit.METADATA_UPDATER_ROLE(), address(dMRVManager));

        // 4. Create an active project owned by `projectOwner`.
        vm.prank(projectOwner);
        registry.registerProject(projectId, "ipfs://project-meta");

        // The admin (`this`) holds the VERIFIER_ROLE and activates the project.
        vm.prank(address(this));
        registry.setProjectStatus(projectId, IProjectRegistry.ProjectStatus.Active);
    }

    // --- Test Placeholders ---

    function test_Unit_Verification_Succeeds() public {
        // --- Arrange ---
        // 1. Define verification parameters.
        uint256 minThreshold = 100;
        uint256 maxTimeDelta = 1 days;
        uint256 oracleValue = 150; // Above threshold
        uint256 oracleTimestamp = block.timestamp; // Fresh data

        // 2. Configure the mock oracle.
        mockOracle.setMockReading(sensorId, oracleValue, oracleTimestamp);

        // 3. Prepare the evidence URI.
        string memory evidenceURI = string(abi.encode(sensorId, minThreshold, maxTimeDelta));

        // 4. Define the expected token ID.
        uint256 expectedTokenId = uint256(projectId);

        // --- Act ---
        // The correct workflow is to call requestVerification on the dMRVManager,
        // which then delegates to our DePINVerifier. We can prank as the projectOwner
        // to simulate them initiating the claim.
        vm.prank(projectOwner);
        dMRVManager.requestVerification(projectId, claimId, evidenceURI, DEPIN_MODULE_ID);

        // --- Assert ---
        // The projectOwner should now have 1 new impact credit token.
        assertEq(credit.balanceOf(projectOwner, expectedTokenId), 1, "Credit should be minted on success");
    }

    function test_Unit_Verification_Fails_If_Reading_Below_Threshold() public {
        // --- Arrange ---
        bytes32 localClaimId = keccak256("claim-below-threshold");
        uint256 minThreshold = 100;
        uint256 maxTimeDelta = 1 days;
        uint256 oracleValue = 50; // Below threshold
        uint256 oracleTimestamp = block.timestamp;

        mockOracle.setMockReading(sensorId, oracleValue, oracleTimestamp);
        string memory evidenceURI = string(abi.encode(sensorId, minThreshold, maxTimeDelta));

        // --- Act ---
        vm.prank(projectOwner);
        dMRVManager.requestVerification(projectId, localClaimId, evidenceURI, DEPIN_MODULE_ID);

        // --- Assert ---
        assertEq(
            credit.balanceOf(projectOwner, uint256(projectId)), 0, "Credit should not be minted on threshold failure"
        );
    }

    function test_Unit_Verification_Fails_If_Data_Is_Stale() public {
        // --- Arrange ---
        bytes32 localClaimId = keccak256("claim-stale-data");
        uint256 minThreshold = 100;
        uint256 maxTimeDelta = 1 days;
        uint256 oracleValue = 150; // Valid value

        // Warp time forward to ensure block.timestamp is large enough for subtraction
        vm.warp(block.timestamp + maxTimeDelta + 2);

        uint256 oracleTimestamp = block.timestamp - (maxTimeDelta + 1); // Stale timestamp

        mockOracle.setMockReading(sensorId, oracleValue, oracleTimestamp);
        string memory evidenceURI = string(abi.encode(sensorId, minThreshold, maxTimeDelta));

        // --- Act ---
        vm.prank(projectOwner);
        dMRVManager.requestVerification(projectId, localClaimId, evidenceURI, DEPIN_MODULE_ID);

        // --- Assert ---
        assertEq(credit.balanceOf(projectOwner, uint256(projectId)), 0, "Credit should not be minted with stale data");
    }

    function test_Unit_Reverts_If_Evidence_Is_Malformed() public {
        // --- Arrange ---
        // Malformed evidence: just a plain string instead of ABI encoded data.
        string memory malformedEvidence = "this is not valid abi data";

        // We expect the DePINVerifier to revert with a specific error.
        vm.expectRevert(abi.encodeWithSelector(DePINVerifier__InvalidEvidenceFormat.selector));

        // --- Act & Assert ---
        vm.prank(projectOwner);
        dMRVManager.requestVerification(projectId, claimId, malformedEvidence, DEPIN_MODULE_ID);
    }

    function test_Unit_Reverts_If_Caller_Is_Not_dMRVManager() public {
        // --- Arrange ---
        string memory evidenceURI = string(abi.encode(sensorId, 100, 1 days));

        // We expect the DePINVerifier to revert because only the dMRVManager can call it.
        vm.expectRevert(DePINVerifier__NotDMRVManager.selector);

        // --- Act & Assert ---
        // Prank as a random user trying to call the function directly.
        vm.prank(randomUser);
        depinVerifier.startVerificationTask(projectId, claimId, evidenceURI);
    }
}
