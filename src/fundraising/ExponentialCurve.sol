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
error ExponentialCurve__ZeroAddress();
error ExponentialCurve__InvalidParameter();
error ExponentialCurve__SlippageExceeded();
error ExponentialCurve__InsufficientBalance();
error ExponentialCurve__WithdrawalLimitExceeded();
error ExponentialCurve__WithdrawalTooSoon();
error ExponentialCurve__VestingNotStarted();
error ExponentialCurve__NothingToClaim();
error ExponentialCurve__TransferFailed();
error ExponentialCurve__OverflowRisk();

/**
 * @title ExponentialCurve
 * @author Genci Mehmeti
 * @dev This contract implements an exponential-like (super-linear) bonding curve, where price = k * supply^2.
 * The token price accelerates as more tokens are minted, making it suitable for high-growth projects.
 * It's a strategy meant to be deployed by the BondingCurveFactory.
 */
contract ExponentialCurve is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IBondingCurveStrategy,
    IProjectBonding
{
    using SafeERC20 for IERC20;

    // --- State Variables ---

    // Core Contracts
    ProjectToken internal _projectToken;
    IERC20 public collateralToken;

    // Bonding Curve Parameters
    uint256 public priceCoefficient; // 'k' in the formula price = k * supply^2

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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // --- Overrides to resolve inheritance conflicts ---

    function owner() public view virtual override(OwnableUpgradeable, IBondingCurveStrategy) returns (address) {
        return OwnableUpgradeable.owner();
    }

    function projectToken() public view virtual override returns (address) {
        return address(_projectToken);
    }

    /**
     * @notice Initializes the exponential curve contract.
     * @dev Called by the BondingCurveFactory. Decodes strategy-specific parameters.
     */
    function initialize(
        address _projectTokenAddress,
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

        _projectToken = ProjectToken(_projectTokenAddress);
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
            _projectToken.mint(address(this), _teamAllocation);
        }
    }

    // --- User-Facing Functions ---

    function buy(uint256 amountToBuy, uint256 maxCollateralToSpend) external override nonReentrant returns (uint256) {
        if (amountToBuy == 0) revert ExponentialCurve__InvalidParameter();

        uint256 cost = _calculateBuyCost(amountToBuy);
        if (cost > maxCollateralToSpend) revert ExponentialCurve__SlippageExceeded();

        collateralAvailableForWithdrawal += cost;
        _projectToken.mint(msg.sender, amountToBuy);

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
        if (amountToSell == 0) revert ExponentialCurve__InvalidParameter();

        uint256 proceeds = _calculateSellProceeds(amountToSell);
        if (proceeds < minCollateralToReceive) revert ExponentialCurve__SlippageExceeded();

        _projectToken.burnFrom(msg.sender, amountToSell);

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
            revert ExponentialCurve__WithdrawalTooSoon();
        }

        uint256 withdrawableAmount =
            (collateralAvailableForWithdrawal * maxWithdrawalPercentage) / PERCENTAGE_DENOMINATOR;
        if (withdrawableAmount == 0) revert ExponentialCurve__WithdrawalLimitExceeded();

        lastWithdrawalTimestamp = block.timestamp;
        collateralAvailableForWithdrawal = 0;

        collateralToken.safeTransfer(owner(), withdrawableAmount);

        emit Withdrawal(owner(), withdrawableAmount);
        return withdrawableAmount;
    }

    function claimVestedTokens() external nonReentrant onlyOwner returns (uint256) {
        if (block.timestamp < vestingCliff) revert ExponentialCurve__VestingNotStarted();

        uint256 vestedAmount = _calculateVestedAmount();
        uint256 claimableAmount = vestedAmount - teamTokensClaimed;

        if (claimableAmount == 0) revert ExponentialCurve__NothingToClaim();

        teamTokensClaimed += claimableAmount;

        _projectToken.transfer(owner(), claimableAmount);
        return claimableAmount;
    }

    /**
     * @notice Releases a specified amount of collateral and project tokens for AMM seeding.
     * @dev This is a privileged function intended to be called by the `BondingCurveFactory`.
     * It is protected by the `onlyOwner` modifier.
     * @param collateralAmount The amount of the collateral token to release.
     * @param projectTokenAmount The amount of the project token to release.
     */
    function releaseLiquidity(uint256 collateralAmount, uint256 projectTokenAmount)
        external
        override
        nonReentrant
        onlyOwner
    {
        if (collateralToken.balanceOf(address(this)) < collateralAmount) {
            revert ExponentialCurve__InsufficientBalance();
        }
        if (_projectToken.balanceOf(address(this)) < projectTokenAmount) {
            revert ExponentialCurve__InsufficientBalance();
        }

        collateralToken.safeTransfer(msg.sender, collateralAmount);
        _projectToken.transfer(msg.sender, projectTokenAmount);
    }

    // --- Internal Math Functions ---

    function _calculateBuyCost(uint256 amountToBuy) internal view returns (uint256) {
        uint256 s1 = _projectToken.totalSupply() - teamAllocation;
        uint256 s2 = s1 + amountToBuy;
        // cost = integral of (k * s^2)ds from s1 to s2
        // cost = k/3 * (s2^3 - s1^3)
        // This calculation carries a risk of overflow if the token supply becomes extremely large.
        if (s2 > 2.2e25) revert ExponentialCurve__OverflowRisk(); // s2^3 must be < uint256.max
        uint256 s2_cubed = s2 * s2 * s2;
        uint256 s1_cubed = s1 * s1 * s1;
        // We divide by WAD three times to account for s being in 18 decimals (WAD), and thus s^3 being in 54 decimals.
        return (priceCoefficient * (s2_cubed - s1_cubed)) / 3 / WAD / WAD / WAD;
    }

    function _calculateSellProceeds(uint256 amountToSell) internal view returns (uint256) {
        uint256 currentSupply = _projectToken.totalSupply() - teamAllocation;
        if (amountToSell > currentSupply) revert ExponentialCurve__InsufficientBalance();
        uint256 s1 = currentSupply;
        uint256 s2 = s1 - amountToSell;
        // proceeds = integral of (k * s^2)ds from s2 to s1
        // proceeds = k/3 * (s1^3 - s2^3)
        if (s1 > 2.2e25) revert ExponentialCurve__OverflowRisk(); // s1^3 must be < uint256.max
        uint256 s1_cubed = s1 * s1 * s1;
        uint256 s2_cubed = s2 * s2 * s2;
        // We divide by WAD three times to account for s being in 18 decimals (WAD), and thus s^3 being in 54 decimals.
        return (priceCoefficient * (s1_cubed - s2_cubed)) / 3 / WAD / WAD / WAD;
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
}
