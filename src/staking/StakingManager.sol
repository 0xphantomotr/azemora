// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

// --- Interfaces ---
interface IPermit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

// --- Custom Errors ---
error StakingManager__ZeroAmount();
error StakingManager__InsufficientStakedAmount();
error StakingManager__WithdrawalNotReady();
error StakingManager__NoUnstakeRequest();
error StakingManager__InvalidDuration();
error StakingManager__TransferFailed();

/**
 * @title StakingManager
 * @author Genci Mehmeti
 * @dev Manages staking of AzemoraToken (AZE) with rewards and slashing capabilities.
 * This contract acts as an economic backstop for the protocol. Stakers' capital is at risk.
 * It is upgradeable using the UUPS pattern.
 */
contract StakingManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    // --- Roles ---
    bytes32 public constant REWARD_ADMIN_ROLE = keccak256("REWARD_ADMIN_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // --- Token ---
    ERC20Upgradeable public stakingToken;

    // --- Staking & Reward State ---
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerShareStored;
    uint256 public periodFinish;
    mapping(address => uint256) public userRewardPerSharePaid;
    mapping(address => uint256) public rewards;

    // --- Unstaking State ---
    struct UnstakeRequest {
        uint256 amount; // This now stores the final token amount to be withdrawn
        uint256 releaseTime;
    }

    mapping(address => UnstakeRequest) public unstakeRequests;
    uint256 public unstakingCooldown;

    // --- Events ---
    event Staked(address indexed user, uint256 amount, uint256 shares);
    event UnstakeInitiated(address indexed user, uint256 shares, uint256 releaseTime);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);
    event RewardRateUpdated(uint256 newRewardRate);
    event Slashed(address indexed caller, address indexed compensationTarget, uint256 amount);
    event CooldownUpdated(uint256 newCooldown);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _stakingToken,
        address _admin,
        address _rewardAdmin,
        address _slasher,
        uint256 _unstakingCooldown
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(REWARD_ADMIN_ROLE, _rewardAdmin);
        _grantRole(SLASHER_ROLE, _slasher);

        stakingToken = ERC20Upgradeable(_stakingToken);
        unstakingCooldown = _unstakingCooldown;
    }

    // --- View Functions ---

    function sharesToTokens(uint256 _shares) public view returns (uint256) {
        if (totalShares == 0) return 0;
        uint256 totalStakedCapital = stakingToken.balanceOf(address(this)) - totalRewardsInPool();
        return (_shares * totalStakedCapital) / totalShares;
    }

    function tokensToShares(uint256 _tokens) public view returns (uint256) {
        if (totalShares == 0) {
            return _tokens; // 1 token = 1 share for initial stake
        }
        uint256 totalStakedCapital = stakingToken.balanceOf(address(this)) - totalRewardsInPool();
        if (totalStakedCapital == 0) {
            return _tokens; // Avoid division by zero if all capital is rewards
        }
        return (_tokens * totalShares) / totalStakedCapital;
    }

    function totalRewardsInPool() public view returns (uint256) {
        if (block.timestamp >= periodFinish) {
            return 0;
        }
        return (periodFinish - block.timestamp) * rewardRate;
    }

    function rewardPerShare() public view returns (uint256) {
        if (totalShares == 0) {
            return rewardPerShareStored;
        }
        uint256 timePoint = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        uint256 timeSinceUpdate = timePoint > lastUpdateTime ? timePoint - lastUpdateTime : 0;
        return rewardPerShareStored + (rewardRate * timeSinceUpdate * 1e18) / totalShares;
    }

    function earned(address account) public view returns (uint256) {
        return (sharesOf[account] * (rewardPerShare() - userRewardPerSharePaid[account])) / 1e18 + rewards[account];
    }

    // --- Core Functions ---

    modifier updateReward(address account) {
        rewardPerShareStored = rewardPerShare();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerSharePaid[account] = rewardPerShareStored;
        }
        _;
    }

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        _stake(msg.sender, amount);
    }

    function stakeWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        updateReward(msg.sender)
    {
        IPermit(address(stakingToken)).permit(msg.sender, address(this), amount, deadline, v, r, s);
        _stake(msg.sender, amount);
    }

    function _stake(address staker, uint256 amount) private {
        // Share calculation must happen BEFORE the transfer changes the contract's balance
        uint256 sharesToMint = tokensToShares(amount);

        if (!stakingToken.transferFrom(staker, address(this), amount)) {
            revert StakingManager__TransferFailed();
        }

        totalShares += sharesToMint;
        sharesOf[staker] += sharesToMint;

        emit Staked(staker, amount, sharesToMint);
    }

    function _addStake(address staker, uint256 amount) private {
        // This function is for compounding, where the tokens are already in the contract.
        // We still calculate shares based on the current state.
        uint256 sharesToMint = tokensToShares(amount);
        totalShares += sharesToMint;
        sharesOf[staker] += sharesToMint;
        emit Staked(staker, amount, sharesToMint);
    }

    function initiateUnstake(uint256 sharesToUnstake) external nonReentrant updateReward(msg.sender) {
        if (sharesToUnstake == 0) revert StakingManager__ZeroAmount();
        if (sharesOf[msg.sender] < sharesToUnstake) revert StakingManager__InsufficientStakedAmount();

        // --- Auto-claim rewards ---
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            if (!stakingToken.transfer(msg.sender, reward)) {
                revert StakingManager__TransferFailed();
            }
            emit RewardPaid(msg.sender, reward);
        }

        // --- Snapshot the token value BEFORE reducing shares ---
        uint256 tokensToWithdraw = sharesToTokens(sharesToUnstake);

        // --- Update share balances ---
        sharesOf[msg.sender] -= sharesToUnstake;
        totalShares -= sharesToUnstake;

        // --- Store the final token amount for withdrawal ---
        unstakeRequests[msg.sender].amount += tokensToWithdraw;
        unstakeRequests[msg.sender].releaseTime = block.timestamp + unstakingCooldown;

        emit UnstakeInitiated(msg.sender, sharesToUnstake, unstakeRequests[msg.sender].releaseTime);
    }

    function withdraw() external nonReentrant {
        UnstakeRequest storage request = unstakeRequests[msg.sender];
        if (request.amount == 0) revert StakingManager__NoUnstakeRequest();
        if (block.timestamp < request.releaseTime) revert StakingManager__WithdrawalNotReady();

        uint256 tokensToWithdraw = request.amount;

        delete unstakeRequests[msg.sender];

        if (!stakingToken.transfer(msg.sender, tokensToWithdraw)) {
            revert StakingManager__TransferFailed();
        }
        // We no longer have the share count, so we emit 0 for that part of the event.
        // This could be improved by storing shares in the request too, but for now, this is the simplest fix.
        emit Withdrawn(msg.sender, tokensToWithdraw, 0);
    }

    function compound() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            _addStake(msg.sender, reward);
        }
    }

    function claimReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            if (!stakingToken.transfer(msg.sender, reward)) {
                revert StakingManager__TransferFailed();
            }
            emit RewardPaid(msg.sender, reward);
        }
    }

    // --- Admin & Privileged Functions ---

    function slash(uint256 slashAmount, address compensationTarget)
        external
        nonReentrant
        onlyRole(SLASHER_ROLE)
        updateReward(address(0))
    {
        if (slashAmount == 0) revert StakingManager__ZeroAmount();

        if (!stakingToken.transfer(compensationTarget, slashAmount)) {
            revert StakingManager__TransferFailed();
        }

        emit Slashed(msg.sender, compensationTarget, slashAmount);
    }

    function notifyRewardAmount(uint256 reward, uint256 duration)
        external
        onlyRole(REWARD_ADMIN_ROLE)
        updateReward(address(0))
    {
        if (duration == 0) revert StakingManager__InvalidDuration();

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / duration;
        }

        if (!stakingToken.transferFrom(msg.sender, address(this), reward)) {
            revert StakingManager__TransferFailed();
        }

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit RewardAdded(reward);
        emit RewardRateUpdated(rewardRate);
    }

    function setUnstakingCooldown(uint256 newCooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        unstakingCooldown = newCooldown;
        emit CooldownUpdated(newCooldown);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
