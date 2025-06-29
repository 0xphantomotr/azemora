// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title Treasury
 * @author Genci Mehmeti
 * @dev A simple contract to hold and manage funds for the Azemora platform.
 * It is owned by the governance system (via the Timelock) and allows for the
 * withdrawal of ETH and any ERC20 tokens.
 */
contract Treasury is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC1155HolderUpgradeable
{
    event ETHWithdrawn(address indexed to, uint256 amount);
    event ERC20Withdrawn(address indexed token, address indexed to, uint256 amount);

    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __ERC1155Holder_init();
    }

    receive() external payable {}

    function withdrawETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Cannot send to zero address");
        require(address(this).balance >= amount, "Insufficient ETH balance");
        (bool success,) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
        emit ETHWithdrawn(to, amount);
    }

    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(0), "Cannot withdraw zero token");
        require(to != address(0), "Cannot send to zero address");
        (bool success,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(success, "ERC20 transfer failed");
        emit ERC20Withdrawn(token, to, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
