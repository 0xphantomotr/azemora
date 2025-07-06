// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IProjectBonding.sol";
import "./ProjectToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IBondingCurveStrategy.sol";

// --- Custom Errors ---
error LogarithmicCurve__ZeroAddress();
error LogarithmicCurve__InvalidParameter();
error LogarithmicCurve__SlippageExceeded();
error LogarithmicCurve__InsufficientBalance();
error LogarithmicCurve__WithdrawalLimitExceeded();
error LogarithmicCurve__WithdrawalTooSoon();
error LogarithmicCurve__VestingNotStarted();
error LogarithmicCurve__NothingToClaim();
error LogarithmicCurve__TransferFailed();
error LogarithmicCurve__OverflowRisk();

/**
 * @title LogarithmicCurve
 * @author Azemora Team
 * @dev This contract implements a logarithmic-like (sub-linear) bonding curve, using a square root function
 * where price is proportional to sqrt(supply). The token price increases at a decreasing rate,
 * encouraging wider initial distribution. It is a strategy meant to be deployed by the BondingCurveFactory.
 */
contract LogarithmicCurve is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IBondingCurveStrategy,
    IProjectBonding
{
    using SafeERC20 for IERC20;

    // --- State Variables ---

    ProjectToken public projectToken;
    IERC20 public collateralToken;

    uint256 public priceCoefficient; // 'k' in the formula price = k * sqrt(supply)

    // Team Vesting Parameters
    uint256 public teamAllocation;
    uint256 public vestingCliff;
    uint256 public vestingDuration;
    uint256 public vestingStartTime;
    uint256 public teamTokensClaimed;

    // Withdrawal Safeguards
    uint256 public maxWithdrawalPercentage;
    uint256 public withdrawalFrequency;
    uint256 public lastWithdrawalTimestamp;
    uint256 public collateralAvailableForWithdrawal;

    uint256 private constant PERCENTAGE_DENOMINATOR = 10000;
    uint256 private constant WAD = 1e18;
    // For sqrt math, s is 18 decimals. s^3 is 54 decimals. sqrt(s^3) is 27 decimals.
    // So we normalize by 10^27.
    uint256 private constant WAD_POW_1_5 = 1e27;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _projectToken,
        address _collateralToken,
        address _projectOwner,
        bytes calldata strategyInitializationData
    ) external override initializer {
        __Ownable_init(_projectOwner);
        __ReentrancyGuard_init();

        (
            uint256 _priceCoefficient,
            uint256 _teamAllocation,
            uint256 _vestingCliffSeconds,
            uint256 _vestingDurationSeconds,
            uint256 _maxWithdrawalPercentage,
            uint256 _withdrawalFrequency
        ) = abi.decode(strategyInitializationData, (uint256, uint256, uint256, uint256, uint256, uint256));

        projectToken = ProjectToken(_projectToken);
        collateralToken = IERC20(_collateralToken);
        priceCoefficient = _priceCoefficient;
        lastWithdrawalTimestamp = block.timestamp;
        maxWithdrawalPercentage = _maxWithdrawalPercentage;
        withdrawalFrequency = _withdrawalFrequency;

        teamAllocation = _teamAllocation;
        if (_teamAllocation > 0) {
            vestingStartTime = block.timestamp;
            vestingCliff = block.timestamp + _vestingCliffSeconds;
            vestingDuration = _vestingDurationSeconds;
            projectToken.mint(address(this), _teamAllocation);
        }
    }

    // --- User-Facing Functions ---

    function buy(uint256 amountToBuy, uint256 maxCollateralToSpend) external override nonReentrant returns (uint256) {
        if (amountToBuy == 0) revert LogarithmicCurve__InvalidParameter();

        uint256 cost = _calculateBuyCost(amountToBuy);
        if (cost > maxCollateralToSpend) revert LogarithmicCurve__SlippageExceeded();

        collateralAvailableForWithdrawal += cost;
        projectToken.mint(msg.sender, amountToBuy);

        collateralToken.safeTransferFrom(msg.sender, address(this), cost);

        emit Buy(msg.sender, cost, amountToBuy);
        return cost;
    }

    function sell(uint256 amountToSell, uint256 minCollateralToReceive)
        external
        override
        nonReentrant
        returns (uint256)
    {
        if (amountToSell == 0) revert LogarithmicCurve__InvalidParameter();

        uint256 proceeds = _calculateSellProceeds(amountToSell);
        if (proceeds < minCollateralToReceive) revert LogarithmicCurve__SlippageExceeded();

        projectToken.burnFrom(msg.sender, amountToSell);

        collateralToken.safeTransfer(msg.sender, proceeds);

        emit Sell(msg.sender, amountToSell, proceeds);
        return proceeds;
    }

    // --- Price Calculation Views ---

    function getBuyPrice(uint256 amountToBuy) external view override returns (uint256) {
        return _calculateBuyCost(amountToBuy);
    }

    function getSellPrice(uint256 amountToSell) external view override returns (uint256) {
        return _calculateSellProceeds(amountToSell);
    }

    // --- Project Owner Functions ---

    function withdrawCollateral() external override nonReentrant onlyOwner returns (uint256) {
        if (block.timestamp < lastWithdrawalTimestamp + withdrawalFrequency) {
            revert LogarithmicCurve__WithdrawalTooSoon();
        }

        uint256 withdrawableAmount =
            (collateralAvailableForWithdrawal * maxWithdrawalPercentage) / PERCENTAGE_DENOMINATOR;
        if (withdrawableAmount == 0) revert LogarithmicCurve__WithdrawalLimitExceeded();

        lastWithdrawalTimestamp = block.timestamp;
        collateralAvailableForWithdrawal = 0;

        collateralToken.safeTransfer(owner(), withdrawableAmount);

        emit Withdrawal(owner(), withdrawableAmount);
        return withdrawableAmount;
    }

    function claimVestedTokens() external nonReentrant onlyOwner returns (uint256) {
        if (block.timestamp < vestingCliff) revert LogarithmicCurve__VestingNotStarted();

        uint256 vestedAmount = _calculateVestedAmount();
        uint256 claimableAmount = vestedAmount - teamTokensClaimed;

        if (claimableAmount == 0) revert LogarithmicCurve__NothingToClaim();

        teamTokensClaimed += claimableAmount;

        projectToken.transfer(owner(), claimableAmount);
        return claimableAmount;
    }

    // --- Internal Math Functions ---

    function _calculateBuyCost(uint256 amountToBuy) internal view returns (uint256) {
        uint256 s1 = projectToken.totalSupply() - teamAllocation;
        uint256 s2 = s1 + amountToBuy;
        // cost = integral of (k * s^(1/2))ds from s1 to s2
        // cost = k * 2/3 * (s2^(3/2) - s1^(3/2))
        // s^(3/2) is calculated as sqrt(s^3) to maintain precision with integer math.
        if (s2 > 2.2e25) revert LogarithmicCurve__OverflowRisk(); // s^3 must be < uint256.max

        uint256 s2_pow_3_2 = _sqrt(s2 * s2 * s2);
        uint256 s1_pow_3_2 = _sqrt(s1 * s1 * s1);
        uint256 diff = s2_pow_3_2 - s1_pow_3_2;

        // The result is normalized by WAD_POW_1_5 because s^(3/2) has 27 decimal places.
        return (priceCoefficient * 2 * diff) / 3 / WAD_POW_1_5;
    }

    function _calculateSellProceeds(uint256 amountToSell) internal view returns (uint256) {
        uint256 currentSupply = projectToken.totalSupply() - teamAllocation;
        if (amountToSell > currentSupply) revert LogarithmicCurve__InsufficientBalance();
        uint256 s1 = currentSupply;
        uint256 s2 = s1 - amountToSell;
        // proceeds = k * 2/3 * (s1^(3/2) - s2^(3/2))
        if (s1 > 2.2e25) revert LogarithmicCurve__OverflowRisk();

        uint256 s1_pow_3_2 = _sqrt(s1 * s1 * s1);
        uint256 s2_pow_3_2 = _sqrt(s2 * s2 * s2);
        uint256 diff = s1_pow_3_2 - s2_pow_3_2;

        return (priceCoefficient * 2 * diff) / 3 / WAD_POW_1_5;
    }

    function _calculateVestedAmount() internal view returns (uint256) {
        if (block.timestamp < vestingStartTime) return 0;

        uint256 vestingEnd = vestingStartTime + vestingDuration;
        if (block.timestamp >= vestingEnd) {
            return teamAllocation;
        }

        if (block.timestamp < vestingCliff) {
            return 0;
        }

        return (teamAllocation * (block.timestamp - vestingStartTime)) / vestingDuration;
    }

    /**
     * @dev A simple Babylonian method for calculating the integer square root.
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
