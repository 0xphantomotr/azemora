// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StakingRewards
 * @dev A contract to manage staking of AzemoraToken (AZE) and distribute rewards.
 * Rewards are funded by marketplace fees or direct transfers from the Treasury.
 * This contract is intentionally simple for clarity and security.
 */
contract StakingRewards is Ownable, ReentrancyGuard {
    IERC20 public immutable rewardsToken; // The token being staked and rewarded (AZE)

    uint256 public totalSupply; // Total amount of tokens staked
    mapping(address => uint256) public balanceOf; // Amount staked by each user

    uint256 public rewardRate; // Rewards distributed per second
    uint256 public lastUpdateTime; // Timestamp of the last reward rate update
    uint256 public rewardPerTokenStored; // Accumulated rewards per token staked
    mapping(address => uint256) public userRewardPerTokenPaid; // Tracks rewards paid to each user
    mapping(address => uint256) public rewards; // Rewards earned but not yet claimed by each user

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardRateUpdated(uint256 newRewardRate);
    event RewardAdded(uint256 reward);

    /**
     * @param _rewardsToken The address of the AzemoraToken (AZE).
     */
    constructor(address _rewardsToken) Ownable(msg.sender) {
        rewardsToken = IERC20(_rewardsToken);
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        uint256 timeSinceUpdate = block.timestamp > lastUpdateTime ? block.timestamp - lastUpdateTime : 0;
        return rewardPerTokenStored + (rewardRate * timeSinceUpdate * 1e18) / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    /**
     * @notice Stakes a specific amount of AZE tokens.
     * @param amount The amount of tokens to stake.
     */
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        require(rewardsToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstakes a specific amount of AZE tokens.
     * @param amount The amount of tokens to unstake.
     */
    function unstake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot unstake 0");
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        require(rewardsToken.transfer(msg.sender, amount), "Token transfer failed");
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claims any earned rewards.
     */
    function claimReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            require(rewardsToken.transfer(msg.sender, reward), "Token transfer failed");
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @notice Notifies the contract that a new amount of rewards has been added.
     * @dev This is the primary way to add rewards (e.g., from marketplace fees).
     * The reward amount is distributed over the specified duration.
     * @param reward The amount of reward tokens added.
     * @param duration The duration in seconds over which to distribute the rewards.
     */
    function notifyRewardAmount(uint256 reward, uint256 duration) external onlyOwner {
        // First, update rewards based on the current rate before changing it.
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        require(duration > 0, "Duration must be > 0");
        // Calculate the new reward rate. This assumes new rewards replace the old distribution plan.
        rewardRate = reward / duration;

        emit RewardAdded(reward);
    }
}
