// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant, Test} from "forge-std/Test.sol";

// Import the TEST-ONLY version of the contract
import {TestableVerifierManager} from "../mocks/TestableVerifierManager.sol";
import {MockReputationManager} from "../mocks/MockReputationManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract VerifierManagerInvariantTest is StdInvariant, Test {
    // --- State Variables ---
    TestableVerifierManager internal verifierManager;
    MockReputationManager internal reputationManager;
    MockERC20 internal stakeToken;

    address internal verifier1 = makeAddr("verifier1");
    address internal verifier2 = makeAddr("verifier2");
    address internal treasury = makeAddr("treasury");
    address[] internal verifiers;

    function setUp() public {
        // --- Deploy Dependencies ---
        stakeToken = new MockERC20("Stake Token", "STK", 18);
        reputationManager = new MockReputationManager();

        // --- Deploy the Testable VerifierManager DIRECTLY (no proxy) ---
        verifierManager = new TestableVerifierManager();
        verifierManager.initialize(
            address(this), // admin
            address(this), // slasher
            treasury,
            address(stakeToken),
            address(reputationManager),
            100e18, // minStakeAmount
            50, // minReputation
            7 days // unstakeLockPeriod
        );

        // --- Setup Verifiers ---
        verifiers.push(verifier1);
        verifiers.push(verifier2);
        stakeToken.mint(verifier1, 1_000e18);
        stakeToken.mint(verifier2, 1_000e18);

        // Give reputation via the mock
        reputationManager.addReputation(verifier1, 100);
        reputationManager.addReputation(verifier2, 100);

        // --- Approve the manager to spend stake ---
        vm.startPrank(verifier1);
        stakeToken.approve(address(verifierManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(verifier2);
        stakeToken.approve(address(verifierManager), type(uint256).max);
        vm.stopPrank();

        // --- Configure Invariant Testing ---
        // We target the contract directly. No proxies. No handlers needed.
        // The fuzzer can now see the ABI perfectly.
        targetContract(address(verifierManager));
        targetSender(verifier1);
        targetSender(verifier2);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 INVARIANTS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev INVARIANT: The contract's balance of stake tokens must always
     *      equal the sum of all individual verifier stakes.
     */
    function invariant_tokenBalanceEqualsSumOfStakes() public view {
        uint256 contractTokenBalance = stakeToken.balanceOf(address(verifierManager));
        uint256 sumOfIndividualStakes;

        for (uint256 i = 0; i < verifiers.length; i++) {
            sumOfIndividualStakes += getVerifierStake(verifiers[i]);
        }

        assertEq(contractTokenBalance, sumOfIndividualStakes, "Invariant Violated: Total stake mismatch");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  GHOST FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Helper to correctly read stake amount from the public getter tuple.
    function getVerifierStake(address verifier) internal view returns (uint256) {
        (uint256 stakeAmount,,,) = verifierManager.verifiers(verifier);
        return stakeAmount;
    }
}
