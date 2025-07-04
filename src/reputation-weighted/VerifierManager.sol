// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../achievements/interfaces/IReputationManager.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/IVerifierManager.sol";

// --- Custom Errors ---
error VerifierManager__NotEnoughReputation();
error VerifierManager__NotEnoughStake();
error VerifierManager__AlreadyRegistered();
error VerifierManager__NotRegistered();
error VerifierManager__UnstakePeriodNotOver();
error VerifierManager__StillStaked();
error VerifierManager__CallerNotArbitrationCouncil();
error VerifierManager__NothingToSlash();
error VerifierManager__ZeroAddress();

/**
 * @title VerifierManager
 * @author Genci Mehmeti
 * @dev Manages the lifecycle of human verifiers in the Azemora ecosystem.
 * It acts as the registry and economic enforcer for the verifier network,
 * requiring participants to meet minimum reputation and stake requirements.
 */
contract VerifierManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IVerifierManager
{
    using SafeERC20 for ERC20Upgradeable;

    // --- Roles ---
    bytes32 public constant ARBITRATION_COUNCIL_ROLE = keccak256("ARBITRATION_COUNCIL_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");

    // --- State ---
    struct Verifier {
        uint256 stake;
        uint256 reputationSnapshot;
        uint256 unstakeAvailableAt; // Timestamp when the verifier can fully withdraw
        bool active;
    }

    ERC20Upgradeable public stakingToken;
    IReputationManager public reputationManager;
    address public treasury;

    uint256 public minStakeAmount;
    uint256 public minReputation;
    uint256 public unstakeLockPeriod; // Duration a verifier must wait to unstake

    mapping(address => Verifier) public verifiers;
    address[] private _verifierList;
    mapping(address => uint256) private _verifierIndex;

    uint256[47] private __gap;

    // --- Events ---
    event Registered(address indexed verifier, uint256 stake, uint256 reputation);
    event UnstakeInitiated(address indexed verifier, uint256 unstakeAvailableAt);
    event Unstaked(address indexed verifier, uint256 stakeReturned);
    event Slashed(address indexed verifier, uint256 stakeSlashed, uint256 reputationSlashed);
    event MinStakeUpdated(uint256 newAmount);
    event MinReputationUpdated(uint256 newAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address arbitrationCouncil_,
        address treasury_,
        address stakingToken_,
        address reputationManager_,
        uint256 minStakeAmount_,
        uint256 minReputation_,
        uint256 unstakeLockPeriod_
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (
            stakingToken_ == address(0) || reputationManager_ == address(0) || admin_ == address(0)
                || arbitrationCouncil_ == address(0) || treasury_ == address(0)
        ) {
            revert VerifierManager__ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ARBITRATION_COUNCIL_ROLE, arbitrationCouncil_);

        treasury = treasury_;
        stakingToken = ERC20Upgradeable(stakingToken_);
        reputationManager = IReputationManager(reputationManager_);
        minStakeAmount = minStakeAmount_;
        minReputation = minReputation_;
        unstakeLockPeriod = unstakeLockPeriod_;
    }

    // --- Verifier Lifecycle Functions ---

    function register() external nonReentrant {
        address user = _msgSender();
        if (verifiers[user].active) revert VerifierManager__AlreadyRegistered();

        uint256 currentReputation = reputationManager.getReputation(user);
        if (currentReputation < minReputation) revert VerifierManager__NotEnoughReputation();

        if (stakingToken.balanceOf(user) < minStakeAmount) revert VerifierManager__NotEnoughStake();

        stakingToken.safeTransferFrom(user, address(this), minStakeAmount);

        verifiers[user] = Verifier({
            stake: minStakeAmount,
            reputationSnapshot: currentReputation,
            unstakeAvailableAt: 0,
            active: true
        });

        _addVerifierToList(user);

        emit Registered(user, minStakeAmount, currentReputation);
    }

    function initiateUnstake() external nonReentrant {
        address user = _msgSender();
        if (!verifiers[user].active) revert VerifierManager__NotRegistered();

        verifiers[user].active = false;
        verifiers[user].unstakeAvailableAt = block.timestamp + unstakeLockPeriod;

        _removeVerifierFromList(user);

        emit UnstakeInitiated(user, verifiers[user].unstakeAvailableAt);
    }

    function unstake() external nonReentrant {
        address user = _msgSender();
        if (verifiers[user].active) revert VerifierManager__StillStaked();
        if (verifiers[user].stake == 0) revert VerifierManager__NotRegistered();
        if (block.timestamp < verifiers[user].unstakeAvailableAt) revert VerifierManager__UnstakePeriodNotOver();

        uint256 stakeToReturn = verifiers[user].stake;
        verifiers[user].stake = 0; // Prevent re-entrancy

        stakingToken.safeTransfer(user, stakeToReturn);

        emit Unstaked(user, stakeToReturn);
    }

    // --- Privileged Functions ---

    /**
     * @notice Slashes a verifier's entire stake.
     * @dev Can only be called by a contract with the SLASHER_ROLE after a successful dispute resolution.
     * The slashed stake is sent to the DAO Treasury.
     * @param verifier The address of the verifier to be slashed.
     */
    function slash(address verifier) external onlyRole(SLASHER_ROLE) nonReentrant {
        Verifier storage v = verifiers[verifier];
        if (!v.active && v.stake == 0) revert VerifierManager__NotRegistered();
        uint256 stakeToSlash = v.stake;
        if (stakeToSlash == 0) revert VerifierManager__NothingToSlash();

        v.stake = 0; // Slashed to zero
        v.active = false; // Deactivate the verifier
        _removeVerifierFromList(verifier); // Remove them from the active list

        // The slashed stake is sent to the DAO Treasury
        stakingToken.safeTransfer(treasury, stakeToSlash);

        // For now, we assume a full reputation slash. This could be made more granular.
        reputationManager.slashReputation(verifier, v.reputationSnapshot);

        emit Slashed(verifier, stakeToSlash, v.reputationSnapshot);
    }

    function setMinStake(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minStakeAmount = newAmount;
        emit MinStakeUpdated(newAmount);
    }

    function setMinReputation(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minReputation = newAmount;
        emit MinReputationUpdated(newAmount);
    }

    // --- View Functions ---

    function getVerifierCount() external view returns (uint256) {
        return _verifierList.length;
    }

    function getAllVerifiers() external view returns (address[] memory) {
        return _verifierList;
    }

    function getVerifierStake(address _verifier) external view returns (uint256) {
        return verifiers[_verifier].stake;
    }

    function isVerifier(address _verifier) external view returns (bool) {
        return verifiers[_verifier].active;
    }

    function getVerifierReputation(address account) external view returns (uint256) {
        return reputationManager.getReputation(account);
    }

    // --- Internal Functions ---

    function _addVerifierToList(address verifier) private {
        _verifierIndex[verifier] = _verifierList.length;
        _verifierList.push(verifier);
    }

    function _removeVerifierFromList(address verifier) private {
        uint256 index = _verifierIndex[verifier];
        uint256 lastIndex = _verifierList.length - 1;

        if (index != lastIndex) {
            address lastVerifier = _verifierList[lastIndex];
            _verifierList[index] = lastVerifier;
            _verifierIndex[lastVerifier] = index;
        }

        _verifierList.pop();
        delete _verifierIndex[verifier];
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
