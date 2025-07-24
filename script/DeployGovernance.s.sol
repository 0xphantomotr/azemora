// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {AzemoraToken} from "../src/token/AzemoraToken.sol";
import {AzemoraTimelockController} from "../src/governance/AzemoraTimelockController.sol";
import {AzemoraGovernor} from "../src/governance/AzemoraGovernor.sol";
import {Treasury} from "../src/governance/Treasury.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployGovernance is Script {
    // Sensible defaults for production
    uint256 private constant DEFAULT_TIMELOCK_MIN_DELAY = 1 days;
    uint48 private constant DEFAULT_GOVERNOR_VOTING_DELAY = 5760; // ~1 day in blocks (15s block time)
    uint32 private constant DEFAULT_GOVERNOR_VOTING_PERIOD = 40320; // ~7 days in blocks (15s block time)
    uint256 private constant DEFAULT_GOVERNOR_PROPOSAL_THRESHOLD = 0;
    uint256 private constant DEFAULT_QUORUM_FRACTION = 4; // Default to 4%

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        // --- Load Config from .env ---
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", DEFAULT_TIMELOCK_MIN_DELAY);
        uint48 votingDelay = uint48(vm.envOr("GOVERNOR_VOTING_DELAY", DEFAULT_GOVERNOR_VOTING_DELAY));
        uint32 votingPeriod = uint32(vm.envOr("GOVERNOR_VOTING_PERIOD", DEFAULT_GOVERNOR_VOTING_PERIOD));
        uint256 proposalThreshold = vm.envOr("GOVERNOR_PROPOSAL_THRESHOLD", DEFAULT_GOVERNOR_PROPOSAL_THRESHOLD);
        uint256 quorumFraction = vm.envOr("GOVERNOR_QUORUM_FRACTION", DEFAULT_QUORUM_FRACTION);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Governance Contracts
        AzemoraToken token = _deployToken();
        AzemoraTimelockController timelock = _deployTimelock(deployerAddress, minDelay);
        AzemoraGovernor governor =
            _deployGovernor(token, timelock, votingDelay, votingPeriod, proposalThreshold, quorumFraction);
        // CRITICAL: The Timelock must own the Treasury to enforce execution delays.
        Treasury treasury = _deployTreasury(address(timelock));

        // 2. Configure Roles
        _configureRoles(timelock, governor);

        // 3. Renounce deployer's admin role on Timelock
        // The deployer gives up control to the DAO (represented by the Governor)
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployerAddress);

        vm.stopBroadcast();

        // 4. Store and Log Addresses
        _storeAndLogAddresses(token, timelock, governor, treasury);
    }

    function _deployToken() internal returns (AzemoraToken) {
        console.log("Deploying AzemoraToken...");
        AzemoraToken impl = new AzemoraToken();
        bytes memory initData = abi.encodeWithSelector(AzemoraToken.initialize.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return AzemoraToken(payable(address(proxy)));
    }

    function _deployTimelock(address admin, uint256 minDelay) internal returns (AzemoraTimelockController) {
        console.log("Deploying AzemoraTimelockController...");
        AzemoraTimelockController impl = new AzemoraTimelockController();
        bytes memory initData = abi.encodeWithSelector(
            AzemoraTimelockController.initialize.selector,
            minDelay,
            new address[](0), // No proposers initially
            new address[](0), // No executors initially
            admin // Deployer is admin to start
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return AzemoraTimelockController(payable(address(proxy)));
    }

    function _deployGovernor(
        AzemoraToken token,
        AzemoraTimelockController timelock,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumFraction
    ) internal returns (AzemoraGovernor) {
        console.log("Deploying AzemoraGovernor...");
        AzemoraGovernor impl = new AzemoraGovernor();
        bytes memory initData = abi.encodeWithSelector(
            AzemoraGovernor.initialize.selector,
            token,
            timelock,
            votingDelay,
            votingPeriod,
            proposalThreshold,
            quorumFraction
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return AzemoraGovernor(payable(address(proxy)));
    }

    function _deployTreasury(address owner) internal returns (Treasury) {
        console.log("Deploying Treasury...");
        Treasury impl = new Treasury();
        bytes memory initData = abi.encodeWithSelector(Treasury.initialize.selector, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return Treasury(payable(address(proxy)));
    }

    function _configureRoles(AzemoraTimelockController timelock, AzemoraGovernor governor) internal {
        console.log("Configuring governance roles...");
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();

        // Governor is the only one who can propose to the Timelock
        timelock.grantRole(proposerRole, address(governor));

        // Anyone can execute a passed proposal
        timelock.grantRole(executorRole, address(0));
    }

    function _storeAndLogAddresses(
        AzemoraToken token,
        AzemoraTimelockController timelock,
        AzemoraGovernor governor,
        Treasury treasury
    ) internal {
        console.log("--- Governance Deployment Complete ---");

        string memory runName = "governance-deployment";
        vm.serializeAddress(runName, "AZEMORA_TOKEN_ADDRESS", address(token));
        vm.serializeAddress(runName, "TIMELOCK_ADDRESS", address(timelock));
        vm.serializeAddress(runName, "GOVERNOR_ADDRESS", address(governor));
        vm.serializeAddress(runName, "TREASURY_ADDRESS", address(treasury));

        console.log("AzemoraToken: ", address(token));
        console.log("Timelock: ", address(timelock));
        console.log("Governor: ", address(governor));
        console.log("Treasury: ", address(treasury));
    }
}
