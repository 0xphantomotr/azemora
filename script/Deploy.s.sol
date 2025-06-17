// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {ProjectRegistry} from "../src/core/ProjectRegistry.sol";
import {DMRVManager} from "../src/core/dMRVManager.sol";
import {DynamicImpactCredit} from "../src/core/DynamicImpactCredit.sol";
import {Marketplace} from "../src/marketplace/Marketplace.sol";
import {DeploymentAddresses} from "./utils/DeploymentAddresses.sol";
import {AzemoraToken} from "../src/token/AzemoraToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Deploy is Script {
    // Role identifiers
    bytes32 public constant DMRV_MANAGER_ROLE = keccak256("DMRV_MANAGER_ROLE");
    bytes32 public constant METADATA_UPDATER_ROLE = keccak256("METADATA_UPDATER_ROLE");

    function run() external returns (address) {
        // --- Setup ---
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address treasuryAddress = vm.envAddress("TREASURY_ADDRESS");
        address paymentTokenAddress = vm.envAddress("TOKEN_ADDRESS");

        if (block.chainid == 31337) {
            vm.deal(deployerAddress, 100 ether);
        }

        vm.startBroadcast(deployerPrivateKey);

        // --- Deployment Sequence ---
        ProjectRegistry projectRegistry = _deployProjectRegistry();
        DynamicImpactCredit dynamicImpactCredit = _deployDynamicImpactCredit(projectRegistry);
        DMRVManager dMRVManager = _deployDMRVManager(projectRegistry, dynamicImpactCredit);
        Marketplace marketplace = _deployMarketplace(dynamicImpactCredit, AzemoraToken(payable(paymentTokenAddress)));

        // --- Post-Deployment Configuration ---
        _configureRoles(dynamicImpactCredit, dMRVManager);
        _configureMarketplace(marketplace, treasuryAddress);

        // --- Store Deployment Addresses ---
        DeploymentAddresses deploymentAddresses = _storeAddresses(
            Addresses({
                projectRegistry: address(projectRegistry),
                dMRVManager: address(dMRVManager),
                dynamicImpactCredit: address(dynamicImpactCredit),
                marketplace: address(marketplace),
                paymentToken: paymentTokenAddress
            })
        );

        vm.stopBroadcast();

        // --- Log Deployed Addresses ---
        _logAddresses(
            AllAddresses({
                projectRegistry: address(projectRegistry),
                dMRVManager: address(dMRVManager),
                dynamicImpactCredit: address(dynamicImpactCredit),
                marketplace: address(marketplace),
                paymentToken: paymentTokenAddress,
                deploymentAddresses: address(deploymentAddresses)
            })
        );

        return address(deploymentAddresses);
    }

    function _deployProjectRegistry() internal returns (ProjectRegistry) {
        console.log("Deploying ProjectRegistry...");
        ProjectRegistry impl = new ProjectRegistry();
        bytes memory initData = abi.encodeWithSelector(ProjectRegistry.initialize.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return ProjectRegistry(payable(address(proxy)));
    }

    function _deployDynamicImpactCredit(ProjectRegistry registry) internal returns (DynamicImpactCredit) {
        console.log("Deploying DynamicImpactCredit...");
        DynamicImpactCredit impl = new DynamicImpactCredit(address(registry));
        bytes memory initData =
            abi.encodeWithSelector(DynamicImpactCredit.initialize.selector, "https://api.azemora.io/contract/d-ic");
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return DynamicImpactCredit(payable(address(proxy)));
    }

    function _deployDMRVManager(ProjectRegistry registry, DynamicImpactCredit credit) internal returns (DMRVManager) {
        console.log("Deploying DMRVManager...");
        DMRVManager impl = new DMRVManager(address(registry), address(credit));
        bytes memory initData = abi.encodeWithSelector(DMRVManager.initialize.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return DMRVManager(payable(address(proxy)));
    }

    function _deployMarketplace(DynamicImpactCredit credit, AzemoraToken paymentToken) internal returns (Marketplace) {
        console.log("Deploying Marketplace...");
        Marketplace impl = new Marketplace();
        bytes memory initData =
            abi.encodeWithSelector(Marketplace.initialize.selector, address(credit), address(paymentToken));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return Marketplace(payable(address(proxy)));
    }

    function _configureRoles(DynamicImpactCredit credit, DMRVManager manager) internal {
        console.log("Granting roles...");
        credit.grantRole(DMRV_MANAGER_ROLE, address(manager));
        credit.grantRole(METADATA_UPDATER_ROLE, address(manager));
    }

    function _configureMarketplace(Marketplace marketplace, address treasury) internal {
        console.log("Setting Marketplace Treasury and Fee...");
        marketplace.setTreasury(treasury);
        marketplace.setFee(250); // 2.5% fee
    }

    struct Addresses {
        address projectRegistry;
        address dMRVManager;
        address dynamicImpactCredit;
        address marketplace;
        address paymentToken;
    }

    function _storeAddresses(Addresses memory addrs) internal returns (DeploymentAddresses) {
        console.log("Storing deployment addresses...");
        DeploymentAddresses deploymentAddresses = new DeploymentAddresses();

        string memory runName = "deployment";
        vm.serializeAddress(runName, "ProjectRegistry", addrs.projectRegistry);
        vm.serializeAddress(runName, "DMRVManager", addrs.dMRVManager);
        vm.serializeAddress(runName, "DynamicImpactCredit", addrs.dynamicImpactCredit);
        vm.serializeAddress(runName, "Marketplace", addrs.marketplace);
        vm.serializeAddress(runName, "PaymentToken", addrs.paymentToken);
        vm.serializeAddress(runName, "DeploymentAddresses", address(deploymentAddresses));
        return deploymentAddresses;
    }

    struct AllAddresses {
        address projectRegistry;
        address dMRVManager;
        address dynamicImpactCredit;
        address marketplace;
        address paymentToken;
        address deploymentAddresses;
    }

    function _logAddresses(AllAddresses memory addrs) internal {
        console.log("--- Deployment Complete ---");
        console.log("ProjectRegistry (Proxy): ", addrs.projectRegistry);
        console.log("DMRVManager (Proxy): ", addrs.dMRVManager);
        console.log("DynamicImpactCredit (Proxy): ", addrs.dynamicImpactCredit);
        console.log("Marketplace (Proxy): ", addrs.marketplace);
        console.log("PaymentToken (AzemoraToken): ", addrs.paymentToken);
        console.log("DeploymentAddresses: ", addrs.deploymentAddresses);
    }
}
