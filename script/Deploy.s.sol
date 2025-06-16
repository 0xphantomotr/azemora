// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {ProjectRegistry} from "../src/core/ProjectRegistry.sol";
import {DMRVManager} from "../src/core/dMRVManager.sol";
import {DynamicImpactCredit} from "../src/core/DynamicImpactCredit.sol";
import {Marketplace} from "../src/marketplace/Marketplace.sol";
import {DeploymentAddresses} from "./utils/DeploymentAddresses.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Deploy is Script {
    // Role identifiers
    bytes32 public constant DMRV_MANAGER_ROLE = keccak256("DMRV_MANAGER_ROLE");
    bytes32 public constant METADATA_UPDATER_ROLE = keccak256("METADATA_UPDATER_ROLE");

    // Deployed contract instances (at proxy addresses)
    ProjectRegistry private _projectRegistry;
    DMRVManager private _dMRVManager;
    DynamicImpactCredit private _dynamicImpactCredit;
    Marketplace private _marketplace;
    ERC20Mock private _mockErc20;

    function run() external returns (address) {
        // --- Setup ---
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        if (block.chainid == 31337) {
            vm.deal(deployerAddress, 100 ether);
        }

        vm.startBroadcast(deployerPrivateKey);

        // --- Deployment Sequence ---

        // 1. ProjectRegistry
        console.log("Deploying ProjectRegistry implementation...");
        ProjectRegistry projectRegistryImpl = new ProjectRegistry();
        console.log("Deploying ProjectRegistry proxy...");
        bytes memory projectRegistryInitData = abi.encodeWithSelector(ProjectRegistry.initialize.selector);
        ERC1967Proxy projectRegistryProxy = new ERC1967Proxy(address(projectRegistryImpl), projectRegistryInitData);
        _projectRegistry = ProjectRegistry(payable(address(projectRegistryProxy)));

        // 2. DynamicImpactCredit
        console.log("Deploying DynamicImpactCredit implementation...");
        DynamicImpactCredit dynamicImpactCreditImpl = new DynamicImpactCredit(address(_projectRegistry));
        console.log("Deploying DynamicImpactCredit proxy...");
        bytes memory dicInitData = abi.encodeWithSelector(DynamicImpactCredit.initialize.selector, "https://api.azemora.io/contract/d-ic");
        ERC1967Proxy dicProxy = new ERC1967Proxy(address(dynamicImpactCreditImpl), dicInitData);
        _dynamicImpactCredit = DynamicImpactCredit(payable(address(dicProxy)));
        
        // 3. dMRVManager
        console.log("Deploying DMRVManager implementation...");
        DMRVManager dMRVManagerImpl = new DMRVManager(address(_projectRegistry), address(_dynamicImpactCredit));
        console.log("Deploying DMRVManager proxy...");
        bytes memory dMRVInitData = abi.encodeWithSelector(DMRVManager.initialize.selector);
        ERC1967Proxy dMRVProxy = new ERC1967Proxy(address(dMRVManagerImpl), dMRVInitData);
        _dMRVManager = DMRVManager(payable(address(dMRVProxy)));

        // 4. MockERC20 (No proxy needed)
        console.log("Deploying MockERC20 as payment token...");
        _mockErc20 = new ERC20Mock();
        _mockErc20.mint(deployerAddress, 1_000_000 * 10 ** 18);

        // 5. Marketplace
        console.log("Deploying Marketplace implementation...");
        Marketplace marketplaceImpl = new Marketplace();
        console.log("Deploying Marketplace proxy...");
        bytes memory marketplaceInitData = abi.encodeWithSelector(Marketplace.initialize.selector, address(_dynamicImpactCredit), address(_mockErc20));
        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplaceImpl), marketplaceInitData);
        _marketplace = Marketplace(payable(address(marketplaceProxy)));

        // --- Post-Deployment Configuration ---
        console.log("Granting roles...");
        _dynamicImpactCredit.grantRole(DMRV_MANAGER_ROLE, address(_dMRVManager));
        _dynamicImpactCredit.grantRole(METADATA_UPDATER_ROLE, address(_dMRVManager));

        console.log("Setting Marketplace Treasury and Fee...");
        _marketplace.setTreasury(deployerAddress);
        _marketplace.setFee(250); // 2.5% fee

        // --- Store Deployment Addresses ---
        console.log("Storing deployment addresses...");
        DeploymentAddresses deploymentAddresses = new DeploymentAddresses();
        
        string memory runName = "deployment";
        vm.serializeAddress(runName, "ProjectRegistry", address(_projectRegistry));
        vm.serializeAddress(runName, "DMRVManager", address(_dMRVManager));
        vm.serializeAddress(runName, "DynamicImpactCredit", address(_dynamicImpactCredit));
        vm.serializeAddress(runName, "Marketplace", address(_marketplace));
        vm.serializeAddress(runName, "ERC20Mock", address(_mockErc20));
        vm.serializeAddress(runName, "DeploymentAddresses", address(deploymentAddresses));

        vm.stopBroadcast();

        console.log("--- Deployment Complete ---");
        console.log("ProjectRegistry (Proxy): ", address(_projectRegistry));
        console.log("DMRVManager (Proxy): ", address(_dMRVManager));
        console.log("DynamicImpactCredit (Proxy): ", address(_dynamicImpactCredit));
        console.log("Marketplace (Proxy): ", address(_marketplace));
        console.log("ERC20Mock (Payment Token): ", address(_mockErc20));
        console.log("DeploymentAddresses: ", address(deploymentAddresses));

        return address(deploymentAddresses);
    }
} 