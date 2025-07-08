// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IPaymaster} from "@account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @title PromotionalPaymaster
 * @author Genci Mehmeti
 * @dev An advanced paymaster that sponsors gas fees based on configurable promotional campaigns.
 * It allows the DAO to set rules like "first X transactions are free" or
 * "sponsor Y total transactions for a limited time," turning the paymaster
 * into a strategic growth and marketing tool.
 */
contract PromotionalPaymaster is IPaymaster {
    IEntryPoint public immutable entryPoint;
    address public owner;

    struct Promotion {
        uint256 id;
        uint256 startTime;
        uint256 endTime;
        uint256 userTxLimit; // Max sponsored txns per user for this promo
        uint256 totalTxLimit; // Max total sponsored txns for this promo
        uint256 sponsoredTxCount; // Counter for total txns in this promo
    }

    Promotion public currentPromotion;

    // Mapping from a promotion ID to a user's sponsored transaction count for that promo.
    mapping(uint256 => mapping(address => uint256)) public userPromotionTxCount;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    event PromotionSet(
        uint256 indexed promotionId, uint256 startTime, uint256 endTime, uint256 userTxLimit, uint256 totalTxLimit
    );
    event PromotionDeactivated();

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        owner = newOwner;
    }

    /**
     * @notice Sets or updates the promotional campaign rules.
     * @dev Only callable by the owner (DAO). Setting userTxLimit and totalTxLimit to 0 effectively
     * deactivates the promotion.
     * @param promotionId A unique ID for the new promotion.
     * @param startTime The timestamp when the promotion becomes active.
     * @param endTime The timestamp when the promotion ends.
     * @param userTxLimit The number of sponsored transactions allowed per user during this promotion.
     * @param totalTxLimit The total number of transactions to be sponsored across all users for this promotion.
     */
    function setPromotion(
        uint256 promotionId,
        uint256 startTime,
        uint256 endTime,
        uint256 userTxLimit,
        uint256 totalTxLimit
    ) external onlyOwner {
        require(startTime < endTime, "start time must be before end time");
        currentPromotion = Promotion({
            id: promotionId,
            startTime: startTime,
            endTime: endTime,
            userTxLimit: userTxLimit,
            totalTxLimit: totalTxLimit,
            sponsoredTxCount: 0
        });
        emit PromotionSet(promotionId, startTime, endTime, userTxLimit, totalTxLimit);
    }

    /**
     * @notice Deactivates the current promotion immediately.
     * @dev A convenience function to quickly halt sponsorships.
     */
    function deactivatePromotion() external onlyOwner {
        delete currentPromotion;
        emit PromotionDeactivated();
    }

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256)
        external
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");

        Promotion memory promo = currentPromotion;
        // Check 1: Is there an active promotion?
        if (promo.id == 0) {
            revert("PromotionalPaymaster: no active promotion");
        }

        // Check 2: Is the promotion currently running?
        if (block.timestamp < promo.startTime || block.timestamp >= promo.endTime) {
            revert("PromotionalPaymaster: promotion not currently active");
        }

        // Check 3: Has the promotion's total budget been reached?
        if (promo.sponsoredTxCount >= promo.totalTxLimit) {
            revert("PromotionalPaymaster: promotion total budget reached");
        }

        // Check 4: Has the user reached their personal limit for this promotion?
        if (userPromotionTxCount[promo.id][userOp.sender] >= promo.userTxLimit) {
            revert("PromotionalPaymaster: user transaction limit reached for this promotion");
        }

        // All checks passed. Pass the user address and promotion ID to postOp.
        return (abi.encode(userOp.sender, promo.id), 0);
    }

    function postOp(IPaymaster.PostOpMode mode, bytes calldata context, uint256, uint256) external override {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");
        // We only update state if the transaction was successful.
        if (mode == IPaymaster.PostOpMode.opSucceeded) {
            (address user, uint256 promotionId) = abi.decode(context, (address, uint256));

            // Ensure the state change is for the promotion that was actually validated.
            if (promotionId == currentPromotion.id) {
                userPromotionTxCount[promotionId][user]++;
                currentPromotion.sponsoredTxCount++;
            }
        }
    }

    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        entryPoint.withdrawStake(withdrawAddress);
    }

    function withdrawTo(address payable withdrawAddress, uint256 amount) public onlyOwner {
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    function deposit() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /**
     * @notice Returns the current promotion details as a struct.
     * @dev A helper function for easier testing and off-chain reading.
     */
    function getPromotion() external view returns (Promotion memory) {
        return currentPromotion;
    }
}
