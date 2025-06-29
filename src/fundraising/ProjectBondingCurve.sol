// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IProjectBonding.sol";
import "./ProjectToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// --- Custom Errors ---
error ProjectBondingCurve__ZeroAddress();
error ProjectBondingCurve__InvalidParameter();
error ProjectBondingCurve__SlippageExceeded();
error ProjectBondingCurve__InsufficientBalance();
error ProjectBondingCurve__WithdrawalLimitExceeded();
error ProjectBondingCurve__WithdrawalTooSoon();
error ProjectBondingCurve__VestingNotStarted();
error ProjectBondingCurve__NothingToClaim();
error ProjectBondingCurve__TransferFailed();
error ProjectBondingCurve__AlreadyInitialized();

/**
 * @title ProjectBondingCurve
 * @author Azemora Team
 * @dev This is the dedicated, project-specific contract that manages the entire market
 * for a single project's token. It holds collateral, mints/burns project tokens based
 * on a linear bonding curve, and enforces vesting and fund withdrawal safeguards.
 * Each verified project gets its own unique instance of this contract, deployed by the Factory.
 */
contract ProjectBondingCurve is IProjectBonding, Ownable, ReentrancyGuard {
    // --- State Variables ---

    // Core Contracts
    ProjectToken public projectToken;
    IERC20 public collateralToken;

    // Bonding Curve Parameters
    uint256 public slope; // Determines the price steepness (price = slope * supply)

    // Team Vesting Parameters
    uint256 public teamAllocation;
    uint256 public vestingCliff; // Absolute timestamp of the cliff
    uint256 public vestingDuration; // Total duration of vesting in seconds
    uint256 public vestingStartTime; // Timestamp when vesting begins
    uint256 public teamTokensClaimed;

    // Withdrawal Safeguards
    uint256 public maxWithdrawalPercentage; // e.g., 1500 for 15.00%
    uint256 public withdrawalFrequency; // e.g., 7 days in seconds
    uint256 public lastWithdrawalTimestamp;
    uint256 public collateralAvailableForWithdrawal;

    uint256 private constant PERCENTAGE_DENOMINATOR = 10000;
    uint256 private constant WAD = 1e18; // For fixed-point math scaling
    bool private _initialized;

    constructor() Ownable(msg.sender) {}

    function initialize(
        address _projectTokenAddress,
        address _collateralTokenAddress,
        address _projectOwner,
        uint256 _slope,
        uint256 _teamAllocation,
        uint256 _vestingCliffSeconds,
        uint256 _vestingDurationSeconds,
        uint256 _maxWithdrawalPercentage,
        uint256 _withdrawalFrequencySeconds
    ) external {
        if (_initialized) revert ProjectBondingCurve__AlreadyInitialized();
        _initialized = true;

        if (_projectTokenAddress == address(0) || _collateralTokenAddress == address(0)) {
            revert ProjectBondingCurve__ZeroAddress();
        }
        if (_slope == 0 || _vestingDurationSeconds == 0) revert ProjectBondingCurve__InvalidParameter();

        _transferOwnership(_projectOwner);

        projectToken = ProjectToken(_projectTokenAddress);
        collateralToken = IERC20(_collateralTokenAddress);
        slope = _slope;
        teamAllocation = _teamAllocation;
        vestingStartTime = block.timestamp;
        vestingCliff = block.timestamp + _vestingCliffSeconds;
        vestingDuration = _vestingDurationSeconds;
        maxWithdrawalPercentage = _maxWithdrawalPercentage;
        withdrawalFrequency = _withdrawalFrequencySeconds;

        if (_teamAllocation > 0) {
            projectToken.mint(address(this), _teamAllocation);
        }
    }

    // --- User-Facing Functions ---

    function buy(uint256 amountToBuy, uint256 maxCollateralToSpend) external nonReentrant returns (uint256) {
        if (amountToBuy == 0) revert ProjectBondingCurve__InvalidParameter();

        uint256 cost = _calculateBuyCost(amountToBuy);
        if (cost > maxCollateralToSpend) revert ProjectBondingCurve__SlippageExceeded();

        collateralAvailableForWithdrawal += cost;
        projectToken.mint(msg.sender, amountToBuy);

        if (!collateralToken.transferFrom(msg.sender, address(this), cost)) {
            revert ProjectBondingCurve__TransferFailed();
        }

        emit Buy(msg.sender, cost, amountToBuy);
        return cost;
    }

    function sell(uint256 amountToSell, uint256 minCollateralToReceive) external nonReentrant returns (uint256) {
        if (amountToSell == 0) revert ProjectBondingCurve__InvalidParameter();

        uint256 proceeds = _calculateSellProceeds(amountToSell);
        if (proceeds < minCollateralToReceive) revert ProjectBondingCurve__SlippageExceeded();

        projectToken.burnFrom(msg.sender, amountToSell);

        if (!collateralToken.transfer(msg.sender, proceeds)) {
            revert ProjectBondingCurve__TransferFailed();
        }

        emit Sell(msg.sender, amountToSell, proceeds);
        return proceeds;
    }

    // --- Price Calculation Views ---

    function getBuyPrice(uint256 amountToBuy) external view returns (uint256) {
        return _calculateBuyCost(amountToBuy);
    }

    function getSellPrice(uint256 amountToSell) external view returns (uint256) {
        return _calculateSellProceeds(amountToSell);
    }

    // --- Project Owner Functions ---

    function withdrawCollateral() external nonReentrant onlyOwner returns (uint256) {
        if (block.timestamp < lastWithdrawalTimestamp + withdrawalFrequency) {
            revert ProjectBondingCurve__WithdrawalTooSoon();
        }

        uint256 withdrawableAmount =
            (collateralAvailableForWithdrawal * maxWithdrawalPercentage) / PERCENTAGE_DENOMINATOR;
        if (withdrawableAmount == 0) revert ProjectBondingCurve__WithdrawalLimitExceeded();

        lastWithdrawalTimestamp = block.timestamp;
        collateralAvailableForWithdrawal = 0;

        if (!collateralToken.transfer(owner(), withdrawableAmount)) {
            revert ProjectBondingCurve__TransferFailed();
        }

        emit Withdrawal(owner(), withdrawableAmount);
        return withdrawableAmount;
    }

    function claimVestedTokens() external nonReentrant onlyOwner returns (uint256) {
        if (block.timestamp < vestingCliff) revert ProjectBondingCurve__VestingNotStarted();

        uint256 vestedAmount = _calculateVestedAmount();
        uint256 claimableAmount = vestedAmount - teamTokensClaimed;

        if (claimableAmount == 0) revert ProjectBondingCurve__NothingToClaim();

        teamTokensClaimed += claimableAmount;

        if (!projectToken.transfer(owner(), claimableAmount)) {
            revert ProjectBondingCurve__TransferFailed();
        }
        return claimableAmount;
    }

    // --- Internal Math Functions ---

    function _calculateBuyCost(uint256 amountToBuy) internal view returns (uint256) {
        uint256 s1 = projectToken.totalSupply() - teamAllocation;
        uint256 s2 = s1 + amountToBuy;
        // cost = integral of (slope * s)ds from s1 to s2
        // cost = slope/2 * (s2^2 - s1^2)
        // We divide by WAD twice to account for s being in 18 decimals (WAD), and thus s^2 being in 36 decimals.
        return (slope * ((s2 * s2) - (s1 * s1))) / 2 / WAD / WAD;
    }

    function _calculateSellProceeds(uint256 amountToSell) internal view returns (uint256) {
        uint256 currentSupply = projectToken.totalSupply() - teamAllocation;
        if (amountToSell > currentSupply) revert ProjectBondingCurve__InsufficientBalance();
        uint256 s1 = currentSupply;
        uint256 s2 = s1 - amountToSell;
        // proceeds = integral of (slope * s)ds from s2 to s1
        // proceeds = slope/2 * (s1^2 - s2^2)
        // We divide by WAD twice to account for s being in 18 decimals (WAD), and thus s^2 being in 36 decimals.
        return (slope * ((s1 * s1) - (s2 * s2))) / 2 / WAD / WAD;
    }

    function _calculateVestedAmount() internal view returns (uint256) {
        if (block.timestamp < vestingStartTime) return 0; // Should not happen

        uint256 vestingEnd = vestingStartTime + vestingDuration;
        if (block.timestamp >= vestingEnd) {
            return teamAllocation;
        }

        if (block.timestamp < vestingCliff) {
            return 0;
        }

        return (teamAllocation * (block.timestamp - vestingStartTime)) / vestingDuration;
    }
}
