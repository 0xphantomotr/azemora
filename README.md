# Azemora: A Web3 Climate Action & Regenerative Finance Platform

This repository contains the smart contract implementation for Azemora, a Web3-based platform focused on climate action and Regenerative Finance (ReFi). The project aims to transparently link verifiable environmental impact, captured through Digital Monitoring, Reporting, and Verification (dMRV) systems, to tokenized environmental assets.

The core of the system is built around Dynamic Non-Fungible Tokens (dNFTs) that represent carbon credits or other environmental assets. The metadata of these dNFTs evolves over time based on verified impact data supplied by oracles, ensuring a transparent and auditable representation of real-world value.

## Core Components

The architecture is modular, separating concerns into distinct, upgradeable smart contracts:

-   `src/core/ProjectRegistry.sol`: Manages the registration and lifecycle of climate action projects. It handles project status (Pending, Active, etc.) and controls access for project updates.
-   `src/core/dMRVManager.sol`: Acts as the gateway for off-chain data. It receives and validates verified impact data from oracles (e.g., Chainlink) and triggers the minting or updating of environmental assets.
-   `src/core/DynamicImpactCredit.sol`: The core dNFT contract, built on the ERC-1155 standard. It manages the creation, ownership, and retirement of tokenized environmental credits. Its metadata is dynamic, reflecting the latest verified impact data.
-   `src/marketplace/Marketplace.sol`: A basic marketplace for listing, buying, and selling the dNFTs, facilitating liquidity and price discovery for the environmental assets.

## Architecture & Design Principles

-   **Modularity**: Each core component is a separate contract, making the system easier to audit, maintain, and upgrade.
-   **Upgradeability**: All core contracts use the UUPS proxy pattern, allowing for logic upgrades without losing state or changing contract addresses.
-   **Security**: The project emphasizes security through extensive testing (unit, complex, fuzz, and invariant tests), use of OpenZeppelin's audited libraries, and adherence to best practices like the Checks-Effects-Interactions pattern.
-   **Dynamic NFTs (ERC-1155)**: The ERC-1155 standard is used to efficiently manage batches of semi-fungible credits whose collective attributes and metadata can evolve based on new dMRV data.

## Technology Stack

-   **Smart Contracts**: Solidity
-   **Development Framework**: [Foundry](https://book.getfoundry.sh/)
-   **Core Libraries**: [OpenZeppelin Contracts (Upgradeable)](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable)
-   **Target Deployment**: Ethereum Layer 2 (ZK-Rollups like Scroll or Polygon zkEVM are primary candidates)

## Project Structure

The project is organized into the following main directories:

-   `src/`: Contains all the smart contract source code.
    -   `core/`: The core logic contracts for the platform.
    -   `marketplace/`: Contracts related to the asset marketplace.
-   `test/`: Contains all the test files, organized by contract.
    -   `ProjectRegistry/`, `DMRVManager/`, `dynamicImpactCredit/`, `Marketplace/`, `Governance/`: Each folder contains unit, complex, fuzz, and/or invariant tests for the corresponding contract.
-   `script/`: Contains deployment scripts.

## Development & Testing

This project uses [Foundry](https://book.getfoundry.sh/). Ensure you have Foundry installed to work with the repository.

### Build

Compile the smart contracts:

```shell
forge build
```

### Run Tests

Run the entire test suite:

```shell
forge test
```

To run tests with a higher verbosity level (e.g., to see traces for failed tests):

```shell
forge test -vvvv
```

To run tests for a specific contract file:

```shell
forge test --match-path test/marketplace/Marketplace.t.sol
```

### Code Formatting

To format the Solidity code according to the project's standards:

```shell
forge fmt
```

### Gas Snapshots

To generate a gas report for the contract functions:

```shell
forge snapshot
```

This will show the estimated gas costs for function calls, helping to identify areas for optimization.
