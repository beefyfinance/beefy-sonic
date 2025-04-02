# BeefySonic

BeefySonic is a liquid staking solution for Sonic tokens on the Sonic network, developed by Beefy. It allows users to stake their Sonic tokens while maintaining liquidity through a tokenized representation (beS) that earns staking rewards.

## Deployment

The contract is deployed at [0x871A101Dcf22fE4fE37be7B654098c801CBA1c88](https://sonicscan.org/address/0x871A101Dcf22fE4fE37be7B654098c801CBA1c88). The implementation contract is deployed at [0x03360fe329F44c6B0bE4d8C89D2fd4c0151b226E](https://sonicscan.org/address/0x03360fe329F44c6B0bE4d8C89D2fd4c0151b226E).

## Overview

BeefySonic enables users to:
- Deposit Sonic tokens and receive beS tokens
- Earn staking rewards automatically
- Request redemption of beS tokens back to Sonic tokens
- Withdraw Sonic tokens after the redemption period
- Protection against validator slashing events

The contract implements the ERC-4626 Tokenized Vault Standard, ERC-7540 Async Redemption Extension, and ERC-7575 Share Token Interface, providing a familiar interface for integrations.

## Key Features

- **Validator Management**: Distributes deposits across multiple validators
- **Automatic Harvesting**: Periodically claims and distributes staking rewards
- **Slashing Protection**: Socializes losses when validators are slashed to protect users
- **Emergency Withdrawals**: Allows users to withdraw funds even during slashing events
- **Fee System**: Configurable fee structure for protocol sustainability
- **Operator System**: Allows users to authorize operators to manage their funds

## Architecture

The system consists of several key components:

- **BeefySonic.sol**: Main contract implementing the ERC-4626 vault
- **BeefySonicStorageUtils.sol**: Storage layout and utilities
- **IBeefySonic.sol**: Interface defining the contract's functions and events
- **ISFC.sol**: Interface for interacting with the Sonic Staking Contract
- **IConstantsManager.sol**: Interface for accessing network constants

## Security Features

BeefySonic implements several security measures:

- **Multi-Validator Withdrawal Distribution**: Large withdrawals are distributed across multiple validators
- **Slashing Protection**: Detects slashed validators and socializes losses across all users
- **Zero Address Checks**: Prevents critical operations with zero addresses
- **Emergency Withdrawal Mode**: Allows users to withdraw funds even during adverse conditions

## Slashing Protection

When a validator is slashed, BeefySonic:
1. Detects the slashing event during regular operations
2. Marks the validator as inactive to prevent further deposits
3. Calculates the recoverable amount based on the slashing refund ratio
4. Initiates the withdrawal process for any recoverable funds
5. Socializes the loss across all users proportionally
6. Allows emergency withdrawals to ensure users can access their funds

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
forge build
```

### Testing

```bash
# Run all tests
forge test

# Run specific test
forge test --match-test test_DepositHarvestWithdraw -vvv

# Generate coverage report
forge coverage --report lcov
```

## Contract Deployment

The BeefySonic contract is designed to be deployed behind a proxy for upgradeability with ownership by a timelock controller. The deployment process involves:

1. Deploy the implementation contract
2. Deploy a proxy pointing to the implementation
3. Initialize the proxy with the required parameters

## License

This project is licensed under MIT License - see the LICENSE file for details.

## Acknowledgements

- [Beefy](https://beefy.com)
- [Sonic](https://soniclabs.com)
- [OpenZeppelin](https://openzeppelin.com) for secure contract libraries
