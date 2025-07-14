// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/depin/DePINVerifier.sol";
import "../../src/depin/interfaces/IOracleManager.sol";
import "../../src/depin/interfaces/IRewardCalculator.sol";
import "../../src/core/interfaces/IDMRVManager.sol";
import "../../src/core/interfaces/IVerificationData.sol";
import "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// --- Custom Errors ---
// By importing the contract file, its file-level errors are available.
import {
    DePINVerifier__NotDMRVManager,
    DePINVerifier__ZeroRewardCalculator,
    DePINVerifier__ZeroAddress
} from "../../src/depin/DePINVerifier.sol";

// --- Mocks ---

contract MockDMRVManager is IDMRVManager {
    bytes32 public lastProjectId;
    bytes32 public lastClaimId;
    IVerificationData.VerificationResult private _lastResult;
    bool public wasCalled;
    bool public wasReversed;

    function fulfillVerification(
        bytes32 projectId,
        bytes32 claimId,
        IVerificationData.VerificationResult calldata result
    ) external {
        lastProjectId = projectId;
        lastClaimId = claimId;
        _lastResult = result;
        wasCalled = true;
    }

    function lastResult() external view returns (IVerificationData.VerificationResult memory) {
        return _lastResult;
    }

    function reverseFulfillment(bytes32 projectId, bytes32 claimId) external {
        lastProjectId = projectId;
        lastClaimId = claimId;
        wasReversed = true;
    }

    function setMethodologyRegistry(address) external {}

    // Mock other functions if needed, otherwise leave empty
    function onDMRVReceived(address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onDMRVReceived.selector;
    }

    function isDMRV(uint256) external pure returns (bool) {
        return true;
    }

    function ownerOf(uint256) external pure returns (address) {
        return address(0);
    }
}

contract MockOracleManager is IOracleManager {
    bool public shouldRevert = false;
    AggregatedReading public readingToReturn;

    function getAggregatedReading(bytes32, bytes32) external view returns (AggregatedReading memory) {
        if (shouldRevert) {
            revert("MockOracleManager: Reverted as requested");
        }
        return readingToReturn;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function setReading(uint256 value, uint256 timestamp) external {
        readingToReturn = AggregatedReading(value, timestamp);
    }
}

contract MockRewardCalculator is IRewardCalculator {
    bool public shouldRevert = false;
    uint256 public rewardToReturn = 100 * 1e18;

    function calculateReward(bytes memory, uint256) external view override returns (uint256) {
        if (shouldRevert) {
            revert("MockRewardCalculator: Reverted as requested");
        }
        return rewardToReturn;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function setRewardToReturn(uint256 _reward) external {
        rewardToReturn = _reward;
    }
}

// A malicious calculator that attempts a re-entrancy attack.
// Note it does NOT implement IRewardCalculator, as its goal is to violate the 'view' modifier.
contract MaliciousRewardCalculator {
    DePINVerifier internal verifier;
    bytes32 internal projectId;
    bytes32 internal claimId;
    string internal evidenceURI;
    bool private reentered;

    constructor(DePINVerifier _verifier) {
        verifier = _verifier;
    }

    // This function has the same signature as IRewardCalculator.calculateReward, but is NOT 'view'.
    function calculateReward(bytes memory, uint256) external returns (uint256) {
        if (!reentered) {
            reentered = true; // Prevent the test from infinitely looping
            // Attempt to re-enter the verifier contract
            verifier.startVerificationTask(projectId, claimId, evidenceURI);
        }
        return 1 ether;
    }

    function setAttackParameters(bytes32 _projectId, bytes32 _claimId, string calldata _evidenceURI) external {
        projectId = _projectId;
        claimId = _claimId;
        evidenceURI = _evidenceURI;
    }
}

// --- Test Contract ---

contract DePINVerifierTest is Test {
    DePINVerifier internal verifier;
    MockDMRVManager internal mockDMRVManager;
    MockOracleManager internal mockOracleManager;
    MockRewardCalculator internal mockRewardCalculator;
    address internal admin;
    address internal user;

    function setUp() public virtual {
        admin = makeAddr("admin");
        user = makeAddr("user");

        mockDMRVManager = new MockDMRVManager();
        mockOracleManager = new MockOracleManager();
        mockRewardCalculator = new MockRewardCalculator();

        // Deploy the implementation
        DePINVerifier implementation = new DePINVerifier();

        // Deploy the proxy and initialize it
        bytes memory initData = abi.encodeWithSelector(
            DePINVerifier.initialize.selector, address(mockDMRVManager), address(mockOracleManager), admin
        );
        verifier = DePINVerifier(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function _buildEvidenceURI(bytes32 sensorId, bytes32 sensorType, address rewardCalculator, bytes memory rewardTerms)
        internal
        pure
        returns (string memory)
    {
        DePINVerifier.VerificationTerms memory terms = DePINVerifier.VerificationTerms({
            sensorId: sensorId,
            sensorType: sensorType,
            rewardCalculator: rewardCalculator,
            rewardTerms: rewardTerms
        });
        return string(abi.encode(terms));
    }

    function test_Initialize_Success() public view {
        assertTrue(verifier.hasRole(verifier.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(address(verifier.dMRVManager()), address(mockDMRVManager));
        assertEq(address(verifier.oracleManager()), address(mockOracleManager));
    }

    function test_StartVerificationTask_Success() public {
        // Arrange
        bytes32 projectId = keccak256("PROJECT_ID");
        bytes32 claimId = keccak256("CLAIM_ID");
        bytes32 sensorId = keccak256("SENSOR_1");
        bytes32 sensorType = keccak256("TEMP");

        mockOracleManager.setReading(72, block.timestamp);
        string memory evidenceURI = _buildEvidenceURI(sensorId, sensorType, address(mockRewardCalculator), "");

        // Act
        vm.prank(address(mockDMRVManager));
        verifier.startVerificationTask(projectId, claimId, evidenceURI);

        // Assert
        assertTrue(mockDMRVManager.wasCalled());
        assertEq(mockDMRVManager.lastProjectId(), projectId);
        assertEq(mockDMRVManager.lastClaimId(), claimId);

        assertEq(mockDMRVManager.lastResult().quantitativeOutcome, mockRewardCalculator.rewardToReturn());
        assertEq(mockDMRVManager.lastResult().wasArbitrated, false);
    }

    function test_RevertIf_CallerIsNotDMRVManager() public {
        // Arrange
        bytes32 projectId = keccak256("PROJECT_ID");
        bytes32 claimId = keccak256("CLAIM_ID");
        string memory evidenceURI = _buildEvidenceURI(0x0, 0x0, address(mockRewardCalculator), "");

        // Act & Assert
        vm.prank(user);
        vm.expectRevert(DePINVerifier__NotDMRVManager.selector);
        verifier.startVerificationTask(projectId, claimId, evidenceURI);
    }

    function test_RevertIf_OracleManagerReverts() public {
        // Arrange
        bytes32 projectId = keccak256("PROJECT_ID");
        bytes32 claimId = keccak256("CLAIM_ID");
        string memory evidenceURI = _buildEvidenceURI(0x0, 0x0, address(mockRewardCalculator), "");

        mockOracleManager.setShouldRevert(true);

        // Act & Assert
        vm.prank(address(mockDMRVManager));
        vm.expectRevert("MockOracleManager: Reverted as requested");
        verifier.startVerificationTask(projectId, claimId, evidenceURI);
    }

    function test_RevertIf_RewardCalculatorReverts() public {
        // Arrange
        bytes32 projectId = keccak256("PROJECT_ID");
        bytes32 claimId = keccak256("CLAIM_ID");
        string memory evidenceURI = _buildEvidenceURI(0x0, 0x0, address(mockRewardCalculator), "");

        mockRewardCalculator.setShouldRevert(true);

        // Act & Assert
        vm.prank(address(mockDMRVManager));
        vm.expectRevert("MockRewardCalculator: Reverted as requested");
        verifier.startVerificationTask(projectId, claimId, evidenceURI);
    }

    function test_RevertIf_ZeroAddressRewardCalculator() public {
        // Arrange
        bytes32 projectId = keccak256("PROJECT_ID");
        bytes32 claimId = keccak256("CLAIM_ID");
        string memory evidenceURI = _buildEvidenceURI(0x0, 0x0, address(0), "");

        // Act & Assert
        vm.prank(address(mockDMRVManager));
        vm.expectRevert(DePINVerifier__ZeroRewardCalculator.selector);
        verifier.startVerificationTask(projectId, claimId, evidenceURI);
    }

    function test_SetOracleManager_Success() public {
        address newOracleManager = makeAddr("newOracleManager");
        vm.prank(admin);
        verifier.setOracleManager(newOracleManager);
        assertEq(address(verifier.oracleManager()), newOracleManager);
    }

    function test_SetOracleManager_RevertIfNotAdmin() public {
        address newOracleManager = makeAddr("newOracleManager");

        // Start pranking as the non-admin user
        vm.startPrank(user);

        // Expect the revert with the user's address
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", user, verifier.DEFAULT_ADMIN_ROLE()
        );
        vm.expectRevert(expectedError);

        // This call will now correctly execute with msg.sender = user
        verifier.setOracleManager(newOracleManager);

        // Stop pranking
        vm.stopPrank();
    }

    // --- Advanced Tests ---

    function test_RevertIf_MalformedEvidenceURI() public {
        // Arrange
        bytes32 projectId = keccak256("PROJECT_ID");
        bytes32 claimId = keccak256("CLAIM_ID");
        string memory malformedURI = "this is not valid abi data";

        // Act & Assert
        vm.prank(address(mockDMRVManager));
        // A raw ABI decoding error does not have a selector, so we do a generic revert check.
        vm.expectRevert();
        verifier.startVerificationTask(projectId, claimId, malformedURI);
    }

    function test_Handles_ZeroRewardCorrectly() public {
        // Arrange
        bytes32 projectId = keccak256("PROJECT_ID");
        bytes32 claimId = keccak256("CLAIM_ID");
        bytes32 sensorId = keccak256("SENSOR_1");
        bytes32 sensorType = keccak256("TEMP");

        mockOracleManager.setReading(72, block.timestamp);
        mockRewardCalculator.setRewardToReturn(0); // The key part of this test

        string memory evidenceURI = _buildEvidenceURI(sensorId, sensorType, address(mockRewardCalculator), "");

        // Act
        vm.prank(address(mockDMRVManager));
        verifier.startVerificationTask(projectId, claimId, evidenceURI);

        // Assert
        assertTrue(mockDMRVManager.wasCalled());
        IVerificationData.VerificationResult memory result = mockDMRVManager.lastResult();
        assertEq(result.quantitativeOutcome, 0);
        assertEq(result.credentialCID, "ipfs://depin-failed-v3");
    }

    function test_RevertIf_ReentrancyAttack() public {
        // Arrange
        bytes32 projectId = keccak256("PROJECT_ID");
        bytes32 claimId = keccak256("CLAIM_ID");
        bytes32 sensorId = keccak256("SENSOR_REENTRANCY");
        bytes32 sensorType = keccak256("TEMP");

        // 1. Deploy the malicious contract
        MaliciousRewardCalculator maliciousCalculator = new MaliciousRewardCalculator(verifier);
        string memory evidenceURI = _buildEvidenceURI(sensorId, sensorType, address(maliciousCalculator), "");

        // 2. Arm the malicious contract with the data it will use to re-enter
        maliciousCalculator.setAttackParameters(projectId, claimId, evidenceURI);
        mockOracleManager.setReading(100, block.timestamp);

        // Act & Assert
        vm.prank(address(mockDMRVManager));

        // 3. Expect the revert.
        // NOTE: The revert does not come from the ReentrancyGuard. It comes from the EVM's
        // `STATICCALL` protection. Because `IRewardCalculator.calculateReward` is a `view`
        // function, Solidity uses a `staticcall` to invoke it. When our malicious calculator
        // tries to call back into the verifier (a state change), the `staticcall` reverts.
        // This is a more fundamental layer of protection than the ReentrancyGuard in this specific path.
        // This test correctly verifies that this protection is active.
        // The revert is generic and does not have specific error data.
        vm.expectRevert();
        verifier.startVerificationTask(projectId, claimId, evidenceURI);
    }

    function test_SetOracleManager_RevertIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(DePINVerifier__ZeroAddress.selector);
        verifier.setOracleManager(address(0));
    }
}
