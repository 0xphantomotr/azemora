// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StakingRewards} from "../../src/staking/StakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ReentrancyAttacker {
    StakingRewards public immutable stakingRewards;
    IERC20 public immutable azemoraToken;

    constructor(address _stakingRewards) {
        stakingRewards = StakingRewards(_stakingRewards);
        azemoraToken = stakingRewards.rewardsToken();
    }

    function stakeTokens(uint256 amount) external {
        azemoraToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);
    }

    function beginAttack() external {
        stakingRewards.claimReward();
    }

    // This function is called by the StakingRewards contract during the transfer.
    // It will try to call back into the StakingRewards contract, triggering the re-entrancy guard.
    receive() external payable {
        // Attempt to re-enter the claimReward function while the first call is still executing
        if (address(stakingRewards).balance > 0) {
            stakingRewards.claimReward();
        }
    }
}
