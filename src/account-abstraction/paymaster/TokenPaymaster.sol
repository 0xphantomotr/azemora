// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IPaymaster} from "@account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import "../interfaces/IPriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenPaymaster
 * @author Genci Mehmeti
 * @dev A self-contained paymaster that allows users to pay for gas using a specific ERC20 token.
 * It implements the IPaymaster interface directly to avoid dependency conflicts.
 */
contract TokenPaymaster is IPaymaster, ReentrancyGuard {
    IEntryPoint public immutable entryPoint;
    IERC20 public immutable token;
    IPriceOracle public immutable oracle;
    address public owner;
    uint256 public feePercentage; // e.g., 5 for a 5% fee

    event TokensCharged(address indexed user, uint256 actualGasCost, uint256 tokenCost);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(IEntryPoint _entryPoint, address _token, address _oracle) {
        entryPoint = _entryPoint;
        token = IERC20(_token);
        oracle = IPriceOracle(_oracle);
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        owner = newOwner;
    }

    function setFeePercentage(uint256 _feePercentage) external onlyOwner {
        feePercentage = _feePercentage;
    }

    function _getRequiredTokenAmount(uint256 gasCostInEthWei) internal view returns (uint256) {
        int256 exchangeRate = oracle.latestAnswer();
        require(exchangeRate > 0, "Invalid exchange rate");
        // Perform all multiplications first to maintain precision before the final division.
        // This avoids potential precision loss from intermediate divisions.
        uint256 costWithFee = gasCostInEthWei * (100 + feePercentage);
        return (costWithFee * uint256(exchangeRate)) / (100 * 1e18);
    }

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256 maxCost)
        external
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");
        uint256 requiredTokenAmount = _getRequiredTokenAmount(maxCost);

        if (token.allowance(userOp.sender, address(this)) < requiredTokenAmount) {
            revert("TokenPaymaster: insufficient token allowance");
        }

        // The context only needs to contain enough information to identify the user in postOp.
        // We no longer pass the token amount here.
        context = abi.encode(userOp.sender);
        return (context, 0);
    }

    function postOp(
        IPaymaster.PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /* actualUserOpFeePerGas */
    ) external override nonReentrant {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");
        // Only charge the user if the main operation succeeded.
        if (mode == IPaymaster.PostOpMode.opSucceeded && context.length > 0) {
            (address user) = abi.decode(context, (address));

            // Calculate the final token cost based on the *actual* gas used.
            uint256 finalTokenCost = _getRequiredTokenAmount(actualGasCost);

            // slither-disable-next-line arbitrary-from
            require(token.transferFrom(user, address(this), finalTokenCost), "TokenPaymaster: transfer failed");
            emit TokensCharged(user, actualGasCost, finalTokenCost);
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
}
