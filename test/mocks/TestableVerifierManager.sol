// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// THIS IS A TEST-ONLY CONTRACT.
// IT IS A COPY OF THE REAL VerifierManager WITH THE CONSTRUCTOR-BASED
// INITIALIZER LOCK COMMENTED OUT TO ALLOW FOR DIRECT DEPLOYMENT AND
// INITIALIZATION IN A TEST ENVIRONMENT.

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../../src/achievements/interfaces/IReputationManager.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

// --- Custom Errors ---
error VerifierManager__NotEnoughReputation();
error VerifierManager__NotEnoughStake();
error VerifierManager__AlreadyRegistered();
error VerifierManager__NotRegistered();
error VerifierManager__UnstakePeriodNotOver();
error VerifierManager__StillStaked();
error VerifierManager__CallerNotSlasher();
error VerifierManager__NothingToSlash();
error VerifierManager__ZeroAddress();

/**
 * @title IVerifierManager
 * @dev Interface for interacting with the VerifierManager.
 */
interface IVerifierManager {
    function isVerifier(address account) external view returns (bool);
    function getVerifierStake(address account) external view returns (uint256);
    function slash(address verifier, uint256 stakeAmount, uint256 reputationAmount) external;
}

/**
 * @title VerifierManager
 * @author Genci Mehmeti
 * @dev Manages the lifecycle of human verifiers in the Azemora ecosystem.
 * It acts as the registry and economic enforcer for the verifier network,
 * requiring participants to meet minimum reputation and stake requirements.
 */
contract TestableVerifierManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IVerifierManager
{
    using SafeERC20 for ERC20Upgradeable;

    // --- Roles ---
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

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

    uint256[49] private __gap;

    // --- Events ---
    event Registered(address indexed verifier, uint256 stake, uint256 reputation);
    event UnstakeInitiated(address indexed verifier, uint256 unstakeAvailableAt);
    event Unstaked(address indexed verifier, uint256 stakeReturned);
    event Slashed(address indexed verifier, uint256 stakeSlashed, uint256 reputationSlashed);
    event MinStakeUpdated(uint256 newAmount);
    event MinReputationUpdated(uint256 newAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // _disableInitializers(); // THIS IS COMMENTED OUT FOR TESTING PURPOSES
    }

    function initialize(
        address admin_,
        address slasher_,
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
                || slasher_ == address(0) || treasury_ == address(0)
        ) {
            revert VerifierManager__ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(SLASHER_ROLE, slasher_);

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

        emit Registered(user, minStakeAmount, currentReputation);
    }

    function initiateUnstake() external nonReentrant {
        address user = _msgSender();
        if (!verifiers[user].active) revert VerifierManager__NotRegistered();

        verifiers[user].active = false;
        verifiers[user].unstakeAvailableAt = block.timestamp + unstakeLockPeriod;

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

    function slash(address verifier, uint256 stakeAmount, uint256 reputationAmount)
        external
        override
        onlyRole(SLASHER_ROLE)
        nonReentrant
    {
        Verifier storage v = verifiers[verifier];
        if (!v.active && v.stake == 0) revert VerifierManager__NotRegistered();
        if (stakeAmount > v.stake) revert VerifierManager__NothingToSlash();

        v.stake -= stakeAmount;

        // The slashed stake is sent to the DAO Treasury
        stakingToken.safeTransfer(treasury, stakeAmount);

        if (reputationAmount > 0) {
            reputationManager.slashReputation(verifier, reputationAmount);
        }

        emit Slashed(verifier, stakeAmount, reputationAmount);
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

    function isVerifier(address account) external view override returns (bool) {
        return verifiers[account].active;
    }

    function getVerifierStake(address account) external view override returns (uint256) {
        return verifiers[account].stake;
    }

    /* ---------- upgrade auth ---------- */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
