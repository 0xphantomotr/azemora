// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/governance/Treasury.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Minimal mock ERC20 to avoid dependency on forge-std/mocks
contract MockERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract TreasuryTest is Test {
    Treasury treasury;
    MockERC20 token;

    address admin = address(0xA11CE);
    address anotherUser = address(0xBEEF);

    function setUp() public {
        token = new MockERC20("Mock Token", "MOCK", 18);

        vm.startPrank(admin);
        Treasury treasuryImpl = new Treasury();
        bytes memory treasuryInitData = abi.encodeCall(Treasury.initialize, (admin));
        ERC1967Proxy treasuryProxy = new ERC1967Proxy(address(treasuryImpl), treasuryInitData);
        treasury = Treasury(payable(address(treasuryProxy)));
        vm.stopPrank();

        // Fund treasury with some ETH and ERC20
        vm.deal(address(treasury), 1 ether);
        token.mint(address(treasury), 1000 * 1e18);
    }

    function test_WithdrawETH_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("Cannot send to zero address");
        treasury.withdrawETH(address(0), 1 ether);
    }

    function test_WithdrawETH_RevertsOnInsufficientBalance() public {
        vm.prank(admin);
        vm.expectRevert("Insufficient ETH balance");
        treasury.withdrawETH(anotherUser, 2 ether);
    }

    function test_WithdrawERC20_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("Cannot send to zero address");
        treasury.withdrawERC20(address(token), address(0), 100 * 1e18);
    }
}
