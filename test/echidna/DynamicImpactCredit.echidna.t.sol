// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ProjectRegistry} from "../../src/core/ProjectRegistry.sol";
import {IProjectRegistry} from "../../src/core/interfaces/IProjectRegistry.sol";
import {DynamicImpactCredit} from "../../src/core/DynamicImpactCredit.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Echidna test for the DynamicImpactCredit contract
/// @notice Defines properties that should always hold true for the DynamicImpactCredit contract.
contract DynamicImpactCreditEchidnaTest is Test {
    ProjectRegistry internal registry;
    DynamicImpactCredit internal credit;

    // --- Actors ---
    address[] internal users;
    address internal admin;
    address internal dMrvManager;
    address internal verifier;

    // --- Assets ---
    bytes32[] internal projectIds;
    uint256[] internal tokenIds;

    // --- State Tracking for Invariants ---
    mapping(uint256 => uint256) public expectedTotalSupply;
    mapping(uint256 => uint256) private expectedUriHistoryLength;

    // --- Constants ---
    uint256 constant NUM_PROJECTS = 5;
    uint256 constant NUM_USERS = 3;

    constructor() {
        // --- Create Actors ---
        admin = address(this);
        dMrvManager = vm.addr(0xAAAA);
        verifier = vm.addr(0xBBBB);
        for (uint256 i = 0; i < NUM_USERS; i++) {
            users.push(vm.addr(uint256(keccak256(abi.encodePacked("user", i)))));
        }

        // --- Deploy & Configure Contracts ---
        vm.prank(admin);
        // 1. Registry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryData = abi.encodeCall(ProjectRegistry.initialize, ());
        registry = ProjectRegistry(payable(address(new ERC1967Proxy(address(registryImpl), registryData))));
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // 2. Credit Contract
        DynamicImpactCredit creditImpl = new DynamicImpactCredit();
        bytes memory creditData =
            abi.encodeCall(DynamicImpactCredit.initializeDynamicImpactCredit, (address(registry), "contract_uri"));
        credit = DynamicImpactCredit(payable(address(new ERC1967Proxy(address(creditImpl), creditData))));
        credit.grantRole(credit.DMRV_MANAGER_ROLE(), dMrvManager);

        // --- Create Projects ---
        for (uint256 i = 0; i < NUM_PROJECTS; i++) {
            address owner = users[i % NUM_USERS];
            bytes32 projectId = keccak256(abi.encodePacked(i, owner));
            projectIds.push(projectId);
            tokenIds.push(uint256(projectId));

            vm.prank(owner);
            registry.registerProject(projectId, "initial_uri");
        }
    }

    // =================================================================
    //                           INVARIANTS
    // =================================================================

    /// @dev Property: The URI history for a token can only grow.
    function echidna_uri_history_is_append_only() public view returns (bool) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 expectedLength = expectedUriHistoryLength[tokenId];
            if (expectedLength > 0) {
                string[] memory history = credit.getCredentialCIDHistory(tokenId);
                if (history.length < expectedLength) {
                    return false; // Invariant violated
                }
            }
        }
        return true;
    }

    /// @dev Property: The total supply of each token should only increase when a valid mint occurs.
    /// This single invariant effectively tests both access control (only DMRV_MANAGER_ROLE) and
    /// state requirements (project must be active).
    function echidna_total_supply_is_conserved() public view returns (bool) {
        for (uint256 i = 0; i < projectIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 actualSupply = 0;

            // Sum balances of all potential holders
            for (uint256 j = 0; j < users.length; j++) {
                actualSupply += credit.balanceOf(users[j], tokenId);
            }
            actualSupply += credit.balanceOf(admin, tokenId);
            actualSupply += credit.balanceOf(dMrvManager, tokenId);
            actualSupply += credit.balanceOf(verifier, tokenId);

            if (actualSupply != expectedTotalSupply[tokenId]) {
                return false; // Invariant violated
            }
        }
        return true;
    }

    // =================================================================
    //                      STATE-CHANGING FUNCTIONS
    // =================================================================

    /// @dev Echidna calls this function to try and mint credits.
    /// The `seed` parameter is used to choose the caller and other inputs.
    function mintCredits(uint256 seed) public {
        // 1. Choose a caller for this transaction based on the seed
        address caller;
        uint256 callerChoice = seed % 4; // 0: manager, 1: admin, 2-3: random user
        if (callerChoice == 0) {
            caller = dMrvManager;
        } else if (callerChoice == 1) {
            caller = admin;
        } else {
            caller = users[seed % NUM_USERS];
        }

        // 2. Choose other parameters based on the seed
        bytes32 projectId = projectIds[seed % NUM_PROJECTS];
        uint256 tokenId = uint256(projectId);
        address to = users[seed % NUM_USERS];
        uint256 amount = (seed % 1000) + 1; // Non-zero amount

        // 3. Predict if the mint should succeed BEFORE the call
        bool canMint = (caller == dMrvManager) || (caller == admin);
        bool projectIsActive = registry.isProjectActive(projectId);
        bool shouldSucceed = canMint && projectIsActive;

        if (shouldSucceed) {
            // 4. Update our expected state ONLY if we predict success
            expectedTotalSupply[tokenId] += amount;
            expectedUriHistoryLength[tokenId]++;
        }

        // 5. Attempt the action with the chosen caller
        // The invariants will later check if the actual state matches our expectations.
        vm.prank(caller);
        try credit.mintCredits(to, projectId, amount, "new_uri") {} catch {}
    }

    /// @dev Echidna calls this function to change project statuses.
    function setProjectStatus(uint256 seed) public {
        // 1. Choose a caller for this transaction
        address caller;
        uint256 callerChoice = seed % 3; // 0: verifier, 1: admin, 2: random user
        if (callerChoice == 0) {
            caller = verifier;
        } else if (callerChoice == 1) {
            caller = admin;
        } else {
            caller = users[seed % NUM_USERS];
        }

        // 2. Choose other parameters
        bytes32 projectId = projectIds[seed % NUM_PROJECTS];
        IProjectRegistry.ProjectStatus status = IProjectRegistry.ProjectStatus((seed / 3) % 4);

        // 3. Attempt the action with the chosen caller
        vm.prank(caller);
        try registry.setProjectStatus(projectId, status) {} catch {}
    }
}
