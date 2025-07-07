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
import {UD60x18} from "@prb/math/src/UD60x18.sol";

// --- Custom Errors ---
error LogarithmicCurve__ZeroAddress();
error LogarithmicCurve__InvalidParameter();
error LogarithmicCurve__SlippageExceeded();
error LogarithmicCurve__SupplyCapReached();
error LogarithmicCurve__NotImplemented();

/**
 * @title LogarithmicCurve
 * @author Azemora Team
 * @dev This contract implements a logarithmic-like bonding curve where price = k / (S_max - supply).
 * The token price is low at the beginning and rises asymptotically towards infinity as it approaches a maximum supply.
 * This heavily incentivizes early investment. It is a strategy meant to be deployed by the BondingCurveFactory.
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

    // Bonding Curve Parameters
    UD60x18 public priceCoefficient; // 'k' in the formula
    UD60x18 public maxSupply; // 'S_max' in the formula

    uint256 private constant WAD = 1e18; // For fixed-point math scaling

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _projectToken,
        address _collateralToken,
        address _projectOwner,
        bytes calldata strategyInitializationData
    ) external initializer {
        __LogarithmicCurve_init(_projectToken, _collateralToken, _projectOwner, strategyInitializationData);
    }

    function __LogarithmicCurve_init(
        address _projectToken,
        address _collateralToken,
        address _projectOwner,
        bytes calldata strategyInitializationData
    ) internal onlyInitializing {
        __Ownable_init(_projectOwner);
        __ReentrancyGuard_init();

        (uint256 _priceCoefficient, uint256 _maxSupply) = abi.decode(strategyInitializationData, (uint256, uint256));

        if (_priceCoefficient == 0 || _maxSupply == 0) revert LogarithmicCurve__InvalidParameter();

        projectToken = ProjectToken(_projectToken);
        collateralToken = IERC20(_collateralToken);
        priceCoefficient = UD60x18.wrap(_priceCoefficient);
        maxSupply = UD60x18.wrap(_maxSupply);
    }

    function buy(uint256 amountToBuy, uint256 maxCollateralToSpend) external override nonReentrant returns (uint256) {
        if (amountToBuy == 0) revert LogarithmicCurve__InvalidParameter();
        uint256 cost = _calculateBuyCost(amountToBuy);
        if (cost > maxCollateralToSpend) revert LogarithmicCurve__SlippageExceeded();

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

    function getBuyPrice(uint256 amountToBuy) external view override returns (uint256) {
        return _calculateBuyCost(amountToBuy);
    }

    function getSellPrice(uint256 amountToSell) external view override returns (uint256) {
        return _calculateSellProceeds(amountToSell);
    }

    function withdrawCollateral() external override onlyOwner returns (uint256) {
        uint256 amount = collateralToken.balanceOf(address(this));
        if (amount > 0) {
            collateralToken.safeTransfer(owner(), amount);
        }
        return amount;
    }

    // --- Internal Math ---

    function _calculateBuyCost(uint256 amountToBuy) internal view returns (uint256) {
        uint256 s1_uint = projectToken.totalSupply();
        uint256 s2_uint = s1_uint + amountToBuy;
        // The prb-math ln() function requires an input >= 1e18.
        // Therefore, (maxSupply - newSupply) must be at least 1e18.
        if (s2_uint > maxSupply.unwrap() - 1e18) revert LogarithmicCurve__SupplyCapReached();

        UD60x18 s1 = UD60x18.wrap(s1_uint);
        UD60x18 s2 = UD60x18.wrap(s2_uint);

        // cost = integral of k/(S_max - s)ds from s1 to s2
        // cost = k * (ln(S_max - s1) - ln(S_max - s2))
        UD60x18 ln1 = (maxSupply.sub(s1)).ln();
        UD60x18 ln2 = (maxSupply.sub(s2)).ln();
        UD60x18 ln_diff = ln1.sub(ln2);

        return priceCoefficient.mul(ln_diff).unwrap();
    }

    function _calculateSellProceeds(uint256 amountToSell) internal view returns (uint256) {
        uint256 s1_uint = projectToken.totalSupply();
        // The check for amountToSell > s1_uint is implicitly handled by `burnFrom`, which will revert.
        UD60x18 s1 = UD60x18.wrap(s1_uint);
        UD60x18 s2 = UD60x18.wrap(s1_uint - amountToSell);

        // proceeds = k * (ln(S_max - s2) - ln(S_max - s1))
        UD60x18 ln1 = (maxSupply.sub(s2)).ln();
        UD60x18 ln2 = (maxSupply.sub(s1)).ln();
        UD60x18 ln_diff = ln1.sub(ln2);

        return priceCoefficient.mul(ln_diff).unwrap();
    }
}
