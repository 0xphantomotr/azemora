// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/ProjectRegistry.sol";
import "../../src/core/dMRVManager.sol";
import "../../src/core/DynamicImpactCredit.sol";
import "../../src/marketplace/Marketplace.sol";
import "../../src/governance/Treasury.sol";
import "../../src/governance/AzemoraTimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Minimal mock ERC20 for Marketplace dependency
contract MockERC20ForHandoff {
    function mint(address, uint256) public {}
}

contract HandoffTest is Test {
    // --- Contracts ---
    ProjectRegistry public registry;
    DMRVManager public dmrvManager;
    DynamicImpactCredit public credit;
    Marketplace public marketplace;
    Treasury public treasury;
    AzemoraTimelockController public timelock;

    // --- Addresses ---
    address public deployer;
    address payable public timelockAddress;

    // --- Roles ---
    bytes32 public ADMIN_ROLE;

    function setUp() public {
        deployer = address(this);
        vm.label(deployer, "Deployer/Admin EOA");

        // --- Deploy All Contracts ---
        // For this test, we deploy them as the 'this' contract (deployer)
        // In a real script, this would be `msg.sender`

        // 1. Deploy Timelock
        AzemoraTimelockController timelockImpl = new AzemoraTimelockController();
        // The timelock will be administered by itself after setup.
        // The deployer is a temporary admin to configure roles.
        bytes memory timelockInitData =
            abi.encodeCall(AzemoraTimelockController.initialize, (1, new address[](0), new address[](0), deployer));
        ERC1967Proxy timelockProxy = new ERC1967Proxy(address(timelockImpl), timelockInitData);
        timelockAddress = payable(address(timelockProxy));
        timelock = AzemoraTimelockController(timelockAddress);
        vm.label(timelockAddress, "TimelockContract");

        // 2. Deploy ProjectRegistry
        ProjectRegistry registryImpl = new ProjectRegistry();
        bytes memory registryInit = abi.encodeCall(ProjectRegistry.initialize, ());
        registry = ProjectRegistry(address(new ERC1967Proxy(address(registryImpl), registryInit)));

        // 3. Deploy DynamicImpactCredit
        DynamicImpactCredit creditImpl = new DynamicImpactCredit(address(registry));
        bytes memory creditInit = abi.encodeCall(DynamicImpactCredit.initialize, ("ipfs://"));
        credit = DynamicImpactCredit(address(new ERC1967Proxy(address(creditImpl), creditInit)));

        // 4. Deploy DMRVManager
        DMRVManager dmrvManagerImpl = new DMRVManager(address(registry), address(credit));
        bytes memory dmrvManagerInit = abi.encodeCall(DMRVManager.initialize, ());
        dmrvManager = DMRVManager(address(new ERC1967Proxy(address(dmrvManagerImpl), dmrvManagerInit)));

        // 5. Deploy Marketplace
        MockERC20ForHandoff paymentToken = new MockERC20ForHandoff();
        Marketplace marketplaceImpl = new Marketplace();
        bytes memory marketplaceInit = abi.encodeCall(Marketplace.initialize, (address(credit), address(paymentToken)));
        marketplace = Marketplace(address(new ERC1967Proxy(address(marketplaceImpl), marketplaceInit)));

        // 6. Deploy Treasury
        Treasury treasuryImpl = new Treasury();
        bytes memory treasuryInit = abi.encodeCall(Treasury.initialize, (deployer));
        treasury = Treasury(payable(address(new ERC1967Proxy(address(treasuryImpl), treasuryInit))));

        // Define a common role hash for easier access
        ADMIN_ROLE = registry.DEFAULT_ADMIN_ROLE();
    }

    /**
     * @notice This test simulates the entire handoff process and verifies the final state.
     * It ensures that after deployment and configuration, the deployer EOA relinquishes all
     * administrative control to the Timelock contract, creating a decentralized system.
     */
    function test_Handoff_And_Renounce_Permissions() public {
        // --- STEP 1: Grant all admin roles to the Timelock contract ---
        // The deployer, who currently holds the admin role, grants it to the Timelock.
        registry.grantRole(ADMIN_ROLE, timelockAddress);
        dmrvManager.grantRole(ADMIN_ROLE, timelockAddress);
        credit.grantRole(ADMIN_ROLE, timelockAddress);
        marketplace.grantRole(ADMIN_ROLE, timelockAddress);

        // For the Ownable Treasury, transfer ownership.
        treasury.transferOwnership(timelockAddress);

        // --- STEP 2: Deployer renounces all admin roles ---
        // This is the critical step. The deployer gives up its power permanently.
        registry.renounceRole(ADMIN_ROLE, deployer);
        dmrvManager.renounceRole(ADMIN_ROLE, deployer);
        credit.renounceRole(ADMIN_ROLE, deployer);
        marketplace.renounceRole(ADMIN_ROLE, deployer);

        // Also renounce the temporary admin role on the timelock itself.
        bytes32 timelockAdminRole = timelock.DEFAULT_ADMIN_ROLE();
        timelock.renounceRole(timelockAdminRole, deployer);

        // --- STEP 3: Verify the final state (The Invariant Check) ---
        // Assert that the deployer EOA no longer has admin power over any contract.
        assertFalse(registry.hasRole(ADMIN_ROLE, deployer), "Deployer MUST NOT have admin on Registry");
        assertFalse(dmrvManager.hasRole(ADMIN_ROLE, deployer), "Deployer MUST NOT have admin on DMRVManager");
        assertFalse(credit.hasRole(ADMIN_ROLE, deployer), "Deployer MUST NOT have admin on Credit Contract");
        assertFalse(marketplace.hasRole(ADMIN_ROLE, deployer), "Deployer MUST NOT have admin on Marketplace");
        assertFalse(timelock.hasRole(timelockAdminRole, deployer), "Deployer MUST NOT have admin on Timelock");

        // Assert that the Timelock IS NOW the sole admin/owner.
        assertTrue(registry.hasRole(ADMIN_ROLE, timelockAddress), "Timelock MUST have admin on Registry");
        assertTrue(dmrvManager.hasRole(ADMIN_ROLE, timelockAddress), "Timelock MUST have admin on DMRVManager");
        assertTrue(credit.hasRole(ADMIN_ROLE, timelockAddress), "Timelock MUST have admin on Credit Contract");
        assertTrue(marketplace.hasRole(ADMIN_ROLE, timelockAddress), "Timelock MUST have admin on Marketplace");
        assertEq(treasury.owner(), timelockAddress, "Timelock MUST be the owner of the Treasury");
    }
}
