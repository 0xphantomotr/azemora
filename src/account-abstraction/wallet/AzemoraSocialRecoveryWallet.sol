// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title AzemoraSocialRecoveryWallet
 * @author Genci Mehmeti
 * @dev A smart contract wallet with a social recovery mechanism.
 * The owner has primary control. A quorum of designated guardians can
 * change the owner after a timelock, providing a robust backup mechanism.
 */
contract AzemoraSocialRecoveryWallet is IAccount, Initializable {
    // --- Events ---
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event GuardianThresholdChanged(uint256 newThreshold);
    event RecoveryProposed(address indexed newOwner);
    event RecoverySupported(address indexed guardian);
    event RecoveryExecuted(address indexed newOwner);
    event RecoveryCancelled();

    // --- State Variables ---
    uint256 private constant SIG_VALIDATION_SUCCESS = 0;
    uint256 private constant SIG_VALIDATION_FAILED = 1;
    uint256 public constant RECOVERY_TIMELOCK = 3 days;

    IEntryPoint public entryPoint;
    address public owner;

    mapping(address => bool) public isGuardian;
    address[] public guardians;
    uint256 public guardianThreshold;

    struct RecoveryProposal {
        address newOwner;
        uint256 approvalCount;
        mapping(address => bool) approvals;
        uint256 proposedAt;
    }

    RecoveryProposal public activeRecovery;
    bool public recoveryIsActive;

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "caller is not the owner");
        _;
    }

    modifier onlyGuardian() {
        require(isGuardian[msg.sender], "caller is not a guardian");
        _;
    }

    // --- Initialization ---
    /**
     * @dev Initializes the social recovery wallet.
     * @param _entryPoint The address of the EntryPoint contract.
     * @param _owner The initial owner of the wallet.
     * @param _guardians The initial set of guardian addresses.
     * @param _threshold The number of guardians required to approve a recovery.
     */
    function initialize(IEntryPoint _entryPoint, address _owner, address[] calldata _guardians, uint256 _threshold)
        public
        initializer
    {
        require(_threshold > 0 && _threshold <= _guardians.length, "Invalid threshold");
        entryPoint = _entryPoint;
        owner = _owner;
        guardianThreshold = _threshold;
        for (uint256 i = 0; i < _guardians.length; i++) {
            address guardian = _guardians[i];
            require(guardian != address(0) && !isGuardian[guardian], "Invalid or duplicate guardian");
            isGuardian[guardian] = true;
            guardians.push(guardian);
        }
    }

    // --- Guardian Management (Owner Only) ---
    function addGuardian(address guardian) external onlyOwner {
        require(guardian != address(0) && !isGuardian[guardian], "Invalid or duplicate guardian");
        isGuardian[guardian] = true;
        guardians.push(guardian);
        emit GuardianAdded(guardian);
    }

    function removeGuardian(address guardian) external onlyOwner {
        require(isGuardian[guardian], "Not a guardian");
        require(guardians.length - 1 >= guardianThreshold, "Cannot remove guardian below threshold");
        isGuardian[guardian] = false;
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == guardian) {
                guardians[i] = guardians[guardians.length - 1];
                guardians.pop();
                break;
            }
        }
        emit GuardianRemoved(guardian);
    }

    function setGuardianThreshold(uint256 _threshold) external onlyOwner {
        require(_threshold > 0 && _threshold <= guardians.length, "Invalid threshold");
        guardianThreshold = _threshold;
        emit GuardianThresholdChanged(_threshold);
    }

    // --- Social Recovery Process ---
    function proposeNewOwner(address _newOwner) external onlyGuardian {
        require(!recoveryIsActive, "Recovery already in progress");
        require(_newOwner != address(0), "Invalid new owner");

        recoveryIsActive = true;
        activeRecovery.newOwner = _newOwner;
        activeRecovery.proposedAt = block.timestamp;
        activeRecovery.approvalCount = 1;
        activeRecovery.approvals[msg.sender] = true;
        emit RecoveryProposed(_newOwner);
        emit RecoverySupported(msg.sender);
    }

    function supportRecovery() external onlyGuardian {
        require(recoveryIsActive, "No active recovery");
        require(!activeRecovery.approvals[msg.sender], "Already supported");

        activeRecovery.approvals[msg.sender] = true;
        activeRecovery.approvalCount++;
        emit RecoverySupported(msg.sender);
    }

    function executeRecovery() external {
        require(recoveryIsActive, "No active recovery");
        require(activeRecovery.approvalCount >= guardianThreshold, "Insufficient approvals");
        require(block.timestamp >= activeRecovery.proposedAt + RECOVERY_TIMELOCK, "Timelock not passed");

        address oldOwner = owner;
        address newOwner = activeRecovery.newOwner;
        owner = newOwner;

        // Reset the recovery state instead of using delete, for clarity
        activeRecovery.newOwner = address(0);
        activeRecovery.approvalCount = 0;
        activeRecovery.proposedAt = 0;
        // The approvals mapping is implicitly reset by the logic in proposeNewOwner
        recoveryIsActive = false;

        emit RecoveryExecuted(newOwner);
        emit OwnerChanged(oldOwner, newOwner);
    }

    function cancelRecovery() external onlyOwner {
        require(recoveryIsActive, "No active recovery");

        // Reset the recovery state instead of using delete, for clarity
        activeRecovery.newOwner = address(0);
        activeRecovery.approvalCount = 0;
        activeRecovery.proposedAt = 0;
        recoveryIsActive = false;

        emit RecoveryCancelled();
    }

    // --- Core EIP-4337 Wallet Logic ---
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256)
        external
        view
        override
        returns (uint256 validationData)
    {
        require(msg.sender == address(entryPoint), "caller must be EntryPoint");
        if (owner != ECDSA.recover(userOpHash, userOp.signature)) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }

    function execute(address dest, uint256 value, bytes calldata func) external {
        _requireFromEntryPointOrOwner();
        _execute(dest, value, func);
    }

    function executeBatch(address[] calldata dest, bytes[] calldata func) external {
        _requireFromEntryPointOrOwner();
        for (uint256 i = 0; i < dest.length; i++) {
            _execute(dest[i], 0, func[i]);
        }
    }

    function _execute(address dest, uint256 value, bytes calldata func) internal {
        // slither-disable-next-line arbitrary-send
        (bool success,) = dest.call{value: value}(func);
        if (!success) {
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _requireFromEntryPointOrOwner() internal view {
        if (msg.sender != address(entryPoint) && msg.sender != owner) {
            revert("sender must be owner or entry point");
        }
    }

    function getGuardians() external view returns (address[] memory) {
        return guardians;
    }

    receive() external payable {}
}
