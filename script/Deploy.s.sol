// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Import the ERC1967Proxy contract
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// --- Azemora Contracts ---
import "../src/token/AzemoraToken.sol";
import "../src/governance/AzemoraTimelockController.sol";
import "../src/governance/AzemoraGovernor.sol";
import "../src/governance/Treasury.sol";
import "../src/core/ProjectRegistry.sol";
import "../src/core/MethodologyRegistry.sol";
import "../src/fundraising/BondingCurveStrategyRegistry.sol";
import "../src/core/DynamicImpactCredit.sol";
import "../src/core/dMRVManager.sol";
import "../src/staking/StakingManager.sol";
import "../src/staking/StakingRewards.sol";
import "../src/marketplace/Marketplace.sol";
import "../src/achievements/ReputationManager.sol";
import "../src/achievements/AchievementsSBT.sol";
import "../src/achievements/QuestManager.sol";
import "../src/reputation-weighted/VerifierManager.sol";
import "../src/governance/ArbitrationCouncil.sol";
import "../src/reputation-weighted/ReputationWeightedVerifier.sol";
import "../src/fundraising/ExponentialCurve.sol";
import "../src/fundraising/LogarithmicCurve.sol";
import "../src/fundraising/ProjectBondingCurve.sol";
import "../src/fundraising/BondingCurveFactory.sol";
import "../src/account-abstraction/wallet/AzemoraSmartWalletFactory.sol";
import "../src/account-abstraction/wallet/AzemoraSocialRecoveryWalletFactory.sol";
import "../src/account-abstraction/paymaster/TokenPaymaster.sol";
import "../src/account-abstraction/paymaster/SponsorPaymaster.sol";
import "../src/account-abstraction/paymaster/PromotionalPaymaster.sol";
import "../src/account-abstraction/core/MockPriceOracle.sol";

// --- External Interfaces ---
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";

contract Deploy is Script {
    // --- State variables to hold deployed addresses ---
    address public azemoraToken;
    address public timelock;
    address public governor;
    address public treasury;
    address public projectRegistry;
    address public methodologyRegistry;
    address public bondingCurveStrategyRegistry;
    address public dynamicImpactCredit;
    address public dmrvManager;
    address public stakingManager;
    address public stakingRewards;
    address public marketplace;
    address public reputationManager;
    address public achievementsSBT;
    address public questManager;
    address public verifierManager;
    address public arbitrationCouncil;
    address public reputationWeightedVerifier;
    address public bondingCurveFactory;
    address public smartWalletFactory;
    address public socialRecoveryWalletFactory;
    address public tokenPaymaster;
    address public sponsorPaymaster;
    address public promotionalPaymaster;
    address public mockOracle;

    function run() external {
        vm.startBroadcast();

        // --- Execute Deployment Phases ---
        _deployGovernancePhase();
        _deployRegistriesAndCorePhase();
        _deployStakingAndMarketplacePhase();
        _deployReputationAndAchievementsPhase();
        _deployArbitrationCouncil();
        _deployVerifierManager();
        _deployReputationWeightedVerifier();
        _deployFundraisingPhase();
        _deployAccountAbstractionPhase();

        // --- FINAL PHASE: Role Configuration ---
        _configureRoles();

        vm.stopBroadcast();

        _logDeployedAddresses();
    }

    // ===================================================================
    // =================== Deployment Helper Functions ===================
    // ===================================================================

    function _deployGovernancePhase() internal {
        console.log("--- Phase 1: Core Governance & Infrastructure ---");

        // --- AzemoraToken ---
        AzemoraToken azeTokenLogic = new AzemoraToken();
        bytes memory azeTokenInitData = abi.encodeWithSelector(AzemoraToken.initialize.selector);
        ERC1967Proxy azeTokenProxy = new ERC1967Proxy(address(azeTokenLogic), azeTokenInitData);
        azemoraToken = address(azeTokenProxy);
        console.log("AzemoraToken proxy deployed at:", azemoraToken);

        // --- AzemoraTimelockController ---
        uint256 minDelay = vm.envUint("TIMELOCK_MIN_DELAY");
        address[] memory proposers = new address[](1);
        proposers[0] = address(0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        AzemoraTimelockController timelockLogic = new AzemoraTimelockController();
        bytes memory timelockInitData =
            abi.encodeWithSelector(timelockLogic.initialize.selector, minDelay, proposers, executors, msg.sender);
        ERC1967Proxy timelockProxy = new ERC1967Proxy(address(timelockLogic), timelockInitData);
        timelock = address(timelockProxy);
        console.log("AzemoraTimelockController proxy deployed at:", timelock);

        // --- AzemoraGovernor ---
        uint48 votingDelay = uint48(vm.envUint("GOVERNOR_VOTING_DELAY"));
        uint32 votingPeriod = uint32(vm.envUint("GOVERNOR_VOTING_PERIOD"));
        uint256 proposalThreshold = vm.envUint("GOVERNOR_PROPOSAL_THRESHOLD");
        uint256 quorumFraction = vm.envUint("GOVERNOR_QUORUM_FRACTION");
        AzemoraGovernor azeGovernorLogic = new AzemoraGovernor();
        bytes memory governorInitData = abi.encodeWithSelector(
            azeGovernorLogic.initialize.selector,
            AzemoraToken(payable(azemoraToken)),
            AzemoraTimelockController(payable(timelock)),
            votingDelay,
            votingPeriod,
            proposalThreshold,
            quorumFraction
        );
        ERC1967Proxy governorProxy = new ERC1967Proxy(address(azeGovernorLogic), governorInitData);
        governor = address(governorProxy);
        console.log("AzemoraGovernor proxy deployed at:", governor);

        // --- Treasury ---
        Treasury treasuryLogic = new Treasury();
        bytes memory treasuryInitData = abi.encodeWithSelector(treasuryLogic.initialize.selector, timelock);
        ERC1967Proxy treasuryProxy = new ERC1967Proxy(address(treasuryLogic), treasuryInitData);
        treasury = address(treasuryProxy);
        console.log("Treasury proxy deployed at:", treasury);
    }

    function _deployRegistriesAndCorePhase() internal {
        console.log("--- Phase 2 & 3: Registries & Core Logic ---");

        // --- ProjectRegistry ---
        ProjectRegistry prLogic = new ProjectRegistry();
        bytes memory prInitData = abi.encodeWithSelector(prLogic.initialize.selector);
        ERC1967Proxy prProxy = new ERC1967Proxy(address(prLogic), prInitData);
        projectRegistry = address(prProxy);
        console.log("ProjectRegistry proxy deployed at:", projectRegistry);

        // --- MethodologyRegistry ---
        MethodologyRegistry mrLogic = new MethodologyRegistry();
        bytes memory mrInitData = abi.encodeWithSelector(mrLogic.initialize.selector, timelock);
        ERC1967Proxy mrProxy = new ERC1967Proxy(address(mrLogic), mrInitData);
        methodologyRegistry = address(mrProxy);
        console.log("MethodologyRegistry proxy deployed at:", methodologyRegistry);

        // --- BondingCurveStrategyRegistry ---
        BondingCurveStrategyRegistry bcsrLogic = new BondingCurveStrategyRegistry();
        bytes memory bcsrInitData = abi.encodeWithSelector(bcsrLogic.initialize.selector, timelock);
        ERC1967Proxy bcsrProxy = new ERC1967Proxy(address(bcsrLogic), bcsrInitData);
        bondingCurveStrategyRegistry = address(bcsrProxy);
        console.log("BondingCurveStrategyRegistry proxy deployed at:", bondingCurveStrategyRegistry);

        // --- DynamicImpactCredit ---
        string memory dynamicImpactCreditURI = vm.envString("DYNAMIC_IMPACT_CREDIT_CONTRACT_URI");
        DynamicImpactCredit dicLogic = new DynamicImpactCredit();
        bytes memory dicInitData = abi.encodeWithSelector(
            dicLogic.initializeDynamicImpactCredit.selector, projectRegistry, dynamicImpactCreditURI
        );
        ERC1967Proxy dicProxy = new ERC1967Proxy(address(dicLogic), dicInitData);
        dynamicImpactCredit = address(dicProxy);
        console.log("DynamicImpactCredit proxy deployed at:", dynamicImpactCredit);

        // --- DMRVManager ---
        DMRVManager dmr_vManagerLogic = new DMRVManager();
        bytes memory dmr_vManagerInitData = abi.encodeWithSelector(
            dmr_vManagerLogic.initializeDMRVManager.selector, projectRegistry, dynamicImpactCredit, methodologyRegistry
        );
        ERC1967Proxy dmr_vManagerProxy = new ERC1967Proxy(address(dmr_vManagerLogic), dmr_vManagerInitData);
        dmrvManager = address(dmr_vManagerProxy);
        console.log("DMRVManager proxy deployed at:", dmrvManager);
    }

    function _deployStakingAndMarketplacePhase() internal {
        console.log("--- Phase 4: Staking & Marketplace ---");

        // --- Marketplace ---
        Marketplace mpLogic = new Marketplace();
        bytes memory mpInitData = abi.encodeWithSelector(mpLogic.initialize.selector, dynamicImpactCredit, azemoraToken);
        ERC1967Proxy mpProxy = new ERC1967Proxy(address(mpLogic), mpInitData);
        marketplace = address(mpProxy);
        console.log("Marketplace proxy deployed at:", marketplace);

        // --- StakingRewards (Not upgradeable) ---
        stakingRewards = address(new StakingRewards(azemoraToken));
        console.log("StakingRewards deployed at:", stakingRewards);

        // --- StakingManager ---
        address initialAdmin = vm.envAddress("INITIAL_ADMIN_ADDRESS");
        uint256 stakingManagerCooldown = vm.envUint("STAKING_MANAGER_UNSTAKING_COOLDOWN");
        StakingManager smLogic = new StakingManager();
        bytes memory smInitData = abi.encodeWithSelector(
            smLogic.initialize.selector, azemoraToken, initialAdmin, marketplace, address(0), stakingManagerCooldown
        );
        ERC1967Proxy smProxy = new ERC1967Proxy(address(smLogic), smInitData);
        stakingManager = address(smProxy);
        console.log("StakingManager proxy deployed at:", stakingManager);
    }

    function _deployReputationAndAchievementsPhase() internal {
        console.log("--- Phase 5: Reputation & Achievements ---");

        // --- ReputationManager ---
        ReputationManager rmLogic = new ReputationManager();
        bytes memory rmInitData = abi.encodeWithSelector(rmLogic.initialize.selector, address(0), address(0));
        ERC1967Proxy rmProxy = new ERC1967Proxy(address(rmLogic), rmInitData);
        reputationManager = address(rmProxy);
        console.log("ReputationManager proxy deployed at:", reputationManager);

        // --- AchievementsSBT ---
        string memory achievementsSbtURI = vm.envString("ACHIEVEMENTS_SBT_CONTRACT_URI");
        AchievementsSBT asbtLogic = new AchievementsSBT();
        bytes memory asbtInitData = abi.encodeWithSelector(asbtLogic.initialize.selector, achievementsSbtURI);
        ERC1967Proxy asbtProxy = new ERC1967Proxy(address(asbtLogic), asbtInitData);
        achievementsSBT = address(asbtProxy);
        console.log("AchievementsSBT proxy deployed at:", achievementsSBT);

        // --- QuestManager ---
        QuestManager qmLogic = new QuestManager();
        bytes memory qmInitData = abi.encodeWithSelector(qmLogic.initialize.selector);
        ERC1967Proxy qmProxy = new ERC1967Proxy(address(qmLogic), qmInitData);
        questManager = address(qmProxy);
        console.log("QuestManager proxy deployed at:", questManager);
    }

    function _deployArbitrationCouncil() internal {
        console.log("--- Phase: Deploying ArbitrationCouncil ---");
        address initialAdmin = vm.envAddress("INITIAL_ADMIN_ADDRESS");
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR_ADDRESS");
        uint256 vrfSubscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");

        ArbitrationCouncil acLogic = new ArbitrationCouncil();
        // Temporarily pass VerifierManager as address(0) because it doesn't exist yet. We will set it later.
        bytes memory acInitData = abi.encodeWithSelector(
            acLogic.initialize.selector,
            initialAdmin,
            azemoraToken,
            address(0), // Placeholder for VerifierManager
            treasury,
            vrfCoordinator,
            vrfSubscriptionId
        );
        ERC1967Proxy acProxy = new ERC1967Proxy(address(acLogic), acInitData);
        arbitrationCouncil = address(acProxy);
        console.log("ArbitrationCouncil proxy deployed at:", arbitrationCouncil);
    }

    function _deployVerifierManager() internal {
        console.log("--- Phase: Deploying VerifierManager ---");
        address initialAdmin = vm.envAddress("INITIAL_ADMIN_ADDRESS");
        uint256 verifierMinStake = vm.envUint("VERIFIER_MANAGER_MIN_STAKE_AMOUNT");
        uint256 verifierMinReputation = vm.envUint("VERIFIER_MANAGER_MIN_REPUTATION");
        uint256 verifierUnstakeLock = vm.envUint("VERIFIER_MANAGER_UNSTAKE_LOCK_PERIOD");

        VerifierManager vmLogic = new VerifierManager();
        bytes memory vmInitData = abi.encodeWithSelector(
            vmLogic.initialize.selector,
            initialAdmin,
            arbitrationCouncil, // Now we have the correct address
            treasury,
            azemoraToken,
            reputationManager,
            verifierMinStake,
            verifierMinReputation,
            verifierUnstakeLock
        );
        ERC1967Proxy vmProxy = new ERC1967Proxy(address(vmLogic), vmInitData);
        verifierManager = address(vmProxy);
        console.log("VerifierManager proxy deployed at:", verifierManager);
    }

    function _deployReputationWeightedVerifier() internal {
        console.log("--- Phase: Deploying ReputationWeightedVerifier ---");
        address initialAdmin = vm.envAddress("INITIAL_ADMIN_ADDRESS");
        uint256 repVerifierVotingPeriod = vm.envUint("REPUTATION_VERIFIER_VOTING_PERIOD");
        uint256 repVerifierChallengePeriod = vm.envUint("REPUTATION_VERIFIER_CHALLENGE_PERIOD");
        uint256 repVerifierApprovalBps = vm.envUint("REPUTATION_VERIFIER_APPROVAL_THRESHOLD_BPS");

        ReputationWeightedVerifier rwvLogic = new ReputationWeightedVerifier();
        bytes memory rwvInitData = abi.encodeWithSelector(
            rwvLogic.initialize.selector,
            initialAdmin,
            verifierManager,
            dmrvManager,
            arbitrationCouncil,
            repVerifierVotingPeriod,
            repVerifierChallengePeriod,
            repVerifierApprovalBps
        );
        ERC1967Proxy rwvProxy = new ERC1967Proxy(address(rwvLogic), rwvInitData);
        reputationWeightedVerifier = address(rwvProxy);
        console.log("ReputationWeightedVerifier proxy deployed at:", reputationWeightedVerifier);
    }

    function _deployFundraisingPhase() internal {
        console.log("--- Phase 8: Fundraising ---");

        // --- Logic Contracts (Not Upgradeable) ---
        address expCurve = address(new ExponentialCurve());
        address logCurve = address(new LogarithmicCurve());
        address projCurve = address(new ProjectBondingCurve());
        console.log("ExponentialCurve logic deployed at:", expCurve);
        console.log("LogarithmicCurve logic deployed at:", logCurve);
        console.log("ProjectBondingCurve logic deployed at:", projCurve);

        // --- BondingCurveFactory (Not Upgradeable) ---
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        bondingCurveFactory =
            address(new BondingCurveFactory(projectRegistry, bondingCurveStrategyRegistry, collateralToken));
        console.log("BondingCurveFactory deployed at:", bondingCurveFactory);
    }

    function _deployAccountAbstractionPhase() internal {
        console.log("--- Phase 9: Account Abstraction ---");
        address entryPointAddress = vm.envAddress("ENTRYPOINT_ADDRESS");
        IEntryPoint entryPoint = IEntryPoint(entryPointAddress);

        // --- Factories and Paymasters (Not Upgradeable) ---
        smartWalletFactory = address(new AzemoraSmartWalletFactory(entryPoint));
        console.log("AzemoraSmartWalletFactory deployed at:", smartWalletFactory);

        socialRecoveryWalletFactory = address(new AzemoraSocialRecoveryWalletFactory(entryPoint));
        console.log("AzemoraSocialRecoveryWalletFactory deployed at:", socialRecoveryWalletFactory);

        int256 mockOraclePrice = int256(vm.envUint("MOCK_ORACLE_INITIAL_AZE_PER_ETH_PRICE"));
        mockOracle = address(new MockPriceOracle(mockOraclePrice));
        console.log("MockPriceOracle deployed at:", mockOracle);

        tokenPaymaster = address(new TokenPaymaster(entryPoint, azemoraToken, mockOracle));
        console.log("TokenPaymaster deployed at:", tokenPaymaster);

        sponsorPaymaster = address(new SponsorPaymaster(entryPoint));
        console.log("SponsorPaymaster deployed at:", sponsorPaymaster);

        promotionalPaymaster = address(new PromotionalPaymaster(entryPoint));
        console.log("PromotionalPaymaster deployed at:", promotionalPaymaster);
    }

    function _configureRoles() internal {
        console.log("--- FINAL PHASE: Configuring All Roles ---");

        // Governance Roles
        AzemoraTimelockController timelockController = AzemoraTimelockController(payable(timelock));
        bytes32 proposerRole = timelockController.PROPOSER_ROLE();
        bytes32 executorRole = timelockController.EXECUTOR_ROLE();
        bytes32 timelockAdminRole = timelockController.DEFAULT_ADMIN_ROLE();
        timelockController.grantRole(proposerRole, governor);
        timelockController.grantRole(executorRole, address(0));
        timelockController.grantRole(timelockAdminRole, timelock);
        timelockController.renounceRole(timelockAdminRole, msg.sender);

        // dMRV Roles
        DynamicImpactCredit dic = DynamicImpactCredit(payable(dynamicImpactCredit));
        bytes32 dicMinterRole = dic.DMRV_MANAGER_ROLE();
        dic.grantRole(dicMinterRole, dmrvManager);
        bytes32 dicBurnerRole = dic.BURNER_ROLE();
        dic.grantRole(dicBurnerRole, dmrvManager);

        // Staking & Marketplace Roles
        StakingManager sm = StakingManager(payable(stakingManager));
        Marketplace mp = Marketplace(payable(marketplace));
        bytes32 rewardAdminRole = sm.REWARD_ADMIN_ROLE();
        sm.grantRole(rewardAdminRole, marketplace);
        bytes32 smSlasherRole = sm.SLASHER_ROLE();
        sm.grantRole(smSlasherRole, arbitrationCouncil);
        mp.setStakingManager(stakingManager);
        mp.setTreasury(treasury);

        // Reputation & Achievements Roles
        ReputationManager rm = ReputationManager(payable(reputationManager));
        bytes32 reputationUpdaterRole = rm.REPUTATION_UPDATER_ROLE();
        rm.grantRole(reputationUpdaterRole, questManager);
        bytes32 reputationSlasherRole = rm.REPUTATION_SLASHER_ROLE();
        rm.grantRole(reputationSlasherRole, verifierManager);

        AchievementsSBT asbt = AchievementsSBT(payable(achievementsSBT));
        bytes32 sbtMinterRole = asbt.MINTER_ROLE();
        asbt.grantRole(sbtMinterRole, questManager);

        // Verifier & Arbitration Roles
        VerifierManager vm_ = VerifierManager(payable(verifierManager));
        ArbitrationCouncil ac = ArbitrationCouncil(payable(arbitrationCouncil));
        bytes32 vmSlasherRole = vm_.SLASHER_ROLE();
        vm_.grantRole(vmSlasherRole, arbitrationCouncil);
        ac.grantRole(ac.VERIFIER_CONTRACT_ROLE(), reputationWeightedVerifier);

        // Post-deployment step to resolve circular dependency
        ArbitrationCouncil(payable(arbitrationCouncil)).setVerifierManager(verifierManager);
    }

    function _logDeployedAddresses() internal {
        console.log("--- ALL DEPLOYED CONTRACTS ---");
        console.log("AzemoraToken:", azemoraToken);
        console.log("AzemoraTimelockController:", timelock);
        console.log("AzemoraGovernor:", governor);
        console.log("Treasury:", treasury);
        console.log("ProjectRegistry:", projectRegistry);
        console.log("MethodologyRegistry:", methodologyRegistry);
        console.log("BondingCurveStrategyRegistry:", bondingCurveStrategyRegistry);
        console.log("DynamicImpactCredit:", dynamicImpactCredit);
        console.log("DMRVManager:", dmrvManager);
        console.log("StakingManager:", stakingManager);
        console.log("StakingRewards:", stakingRewards);
        console.log("Marketplace:", marketplace);
        console.log("ReputationManager:", reputationManager);
        console.log("AchievementsSBT:", achievementsSBT);
        console.log("QuestManager:", questManager);
        console.log("VerifierManager:", verifierManager);
        console.log("ArbitrationCouncil:", arbitrationCouncil);
        console.log("ReputationWeightedVerifier:", reputationWeightedVerifier);
        console.log("BondingCurveFactory:", bondingCurveFactory);
        console.log("AzemoraSmartWalletFactory:", smartWalletFactory);
        console.log("AzemoraSocialRecoveryWalletFactory:", socialRecoveryWalletFactory);
        console.log("TokenPaymaster:", tokenPaymaster);
        console.log("SponsorPaymaster:", sponsorPaymaster);
        console.log("PromotionalPaymaster:", promotionalPaymaster);
        console.log("MockPriceOracle:", mockOracle);
    }
}
