// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenBalanceVerifier} from "../../src/achievements/verifiers/TokenBalanceVerifier.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// --- Mocks ---

contract MockToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    string public constant name = "Mock Token";
    string public constant symbol = "MKT";
    uint8 public constant decimals = 18;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function totalSupply() external pure returns (uint256) {
        return type(uint256).max;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// --- Tests ---

contract TokenBalanceVerifierTest is Test {
    // --- Test setup ---
    TokenBalanceVerifier internal verifier;
    MockToken internal mockToken;

    // --- Users ---
    address internal owner;
    address internal userWithBalance;
    address internal userWithoutBalance;

    // --- Constants ---
    uint256 internal constant MIN_BALANCE = 100 * 1e18;

    function setUp() public {
        owner = makeAddr("owner");
        userWithBalance = makeAddr("userWithBalance");
        userWithoutBalance = makeAddr("userWithoutBalance");

        mockToken = new MockToken();
        mockToken.mint(userWithBalance, MIN_BALANCE); // Mint exact amount

        verifier = new TokenBalanceVerifier(address(mockToken), MIN_BALANCE, owner);
    }

    // --- Test Constructor ---

    function test_reverts_constructor_withZeroAddress() public {
        vm.expectRevert(TokenBalanceVerifier.TokenBalanceVerifier__InvalidAddress.selector);
        new TokenBalanceVerifier(address(0), MIN_BALANCE, owner);
    }

    function test_reverts_constructor_withZeroAmount() public {
        vm.expectRevert(TokenBalanceVerifier.TokenBalanceVerifier__InvalidAmount.selector);
        new TokenBalanceVerifier(address(mockToken), 0, owner);
    }

    // --- Test verify ---

    function test_verify_returnsTrue_forUserWithSufficientBalance() public view {
        assertTrue(verifier.verify(userWithBalance), "Should be true for sufficient balance");
    }

    function test_verify_returnsTrue_forUserWithMoreThanSufficientBalance() public {
        mockToken.mint(userWithBalance, 1); // Add a little extra
        assertTrue(verifier.verify(userWithBalance), "Should be true for more than sufficient balance");
    }

    function test_verify_returnsFalse_forUserWithInsufficientBalance() public view {
        assertFalse(verifier.verify(userWithoutBalance), "Should be false for insufficient balance");
    }

    // --- Test setMinBalance ---

    function test_setMinBalance_updatesBalanceAndEmitsEvent() public {
        uint256 newMinBalance = 200 * 1e18;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TokenBalanceVerifier.MinBalanceUpdated(newMinBalance);
        verifier.setMinBalance(newMinBalance);

        assertEq(verifier.minBalanceRequired(), newMinBalance, "Minimum balance not updated");
    }

    function test_setMinBalance_reverts_ifNotOwner() public {
        vm.startPrank(userWithBalance);
        bytes memory expectedRevert = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userWithBalance);
        vm.expectRevert(expectedRevert);
        verifier.setMinBalance(200 * 1e18);
        vm.stopPrank();
    }

    function test_setMinBalance_reverts_withZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(TokenBalanceVerifier.TokenBalanceVerifier__InvalidAmount.selector);
        verifier.setMinBalance(0);
    }

    function test_verify_reflectsNewMinBalance() public {
        // Initially, user has enough
        assertTrue(verifier.verify(userWithBalance));

        // Update requirement to be higher than user's balance
        uint256 newMinBalance = MIN_BALANCE + 1;
        vm.prank(owner);
        verifier.setMinBalance(newMinBalance);

        // Now, user should fail verification
        assertFalse(verifier.verify(userWithBalance), "Verification did not fail after increasing min balance");
    }
}
