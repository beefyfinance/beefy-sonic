# BeefySonic

BeefySonic is a liquid staking solution for Sonic tokens on the Sonic network, developed by Beefy Finance. It allows users to stake their Sonic tokens while maintaining liquidity through a tokenized representation (beS) that earns staking rewards.

## Overview

BeefySonic enables users to:
- Deposit Sonic tokens and receive beS tokens
- Earn staking rewards automatically
- Request redemption of beS tokens back to Sonic tokens
- Withdraw Sonic tokens after the redemption period

The contract implements the ERC-4626 Tokenized Vault Standard and ERC-7540 Async Redemption Extension, providing a familiar interface for integrations.

## Key Features

- **Validator Management**: Distributes deposits across multiple validators
- **Automatic Harvesting**: Periodically claims and distributes staking rewards
- **Withdrawal Protection**: Implements safeguards against withdrawal DDoS attacks
- **Fee System**: Configurable fee structure for protocol sustainability

## Architecture

The system consists of several key components:

- **BeefySonic.sol**: Main contract implementing the ERC-4626 vault
- **IBeefySonic.sol**: Interface defining the contract's functions and events
- **ISFC.sol**: Interface for interacting with the Sonic Staking Contract

## Security Features

BeefySonic implements several security measures to prevent DDoS attacks:

- **Minimum Withdrawal Amount**: Prevents dust attacks by enforcing a minimum withdrawal size
- **Epoch-Based Withdrawal Limits**: Each validator tracks the last epoch in which a withdrawal was processed, preventing multiple withdrawals from the same validator in the same epoch
- **Validator Skipping Logic**: During withdrawals, the contract skips validators that have already processed a withdrawal in the current epoch
- **Multi-Validator Withdrawal Distribution**: Large withdrawals are distributed across multiple validators

These mechanisms work together to ensure fair access to withdrawal functionality while preventing malicious users from monopolizing the withdrawal capacity, even when using multiple wallets.

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js and npm/yarn

### Installation

```bash
# Clone the repository
git clone https://github.com/beefyfinance/beefy-sonic.git
cd beefy-sonic

# Install dependencies
yarn install

# Build the contracts
yarn build
```

### Testing

```bash
# Run all tests
yarn test

# Run specific test
forge test --match-test test_DepositHarvestWithdraw -vvv
```

## Contract Deployment

The BeefySonic contract is designed to be deployed behind a proxy for upgradeability with ownership by a timelock controller. The deployment process involves:

1. Deploy the implementation contract
2. Deploy a proxy pointing to the implementation
3. Initialize the proxy with the required parameters

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgements

- [Beefy](https://beefy.com)
- [Sonic](https://soniclabs.com)
- [OpenZeppelin](https://openzeppelin.com) for secure contract libraries
