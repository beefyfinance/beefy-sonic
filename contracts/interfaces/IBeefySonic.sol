// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;


interface IBeefySonic {
   struct BeefySonicStorage {
        // Address of the underlying token
        address want;
        // Address of the staking contract
        address stakingContract;
        // Address of the Beefy fee recipient
        address beefyFeeRecipient;
        // Address of the liquidity fee recipient
        address liquidityFeeRecipient;
        // Address of the Beefy fee configuration
        address beefyFeeConfig;
        // Liquidity fee percentage
        uint256 liquidityFee;
        // Total amount of tokens stored
        uint256 storedTotal;
        // Total amount of tokens locked
        uint256 totalLocked;
        // Last time notify was called
        uint256 lastHarvest;
        // Duration to lock tokens
        uint256 lockDuration;
        // Duration to withdraw tokens
        uint256 withdrawDuration;
        // Withdraw request ID
        uint256 withdrawRequestId;
        // Queued withdrawals
        mapping(address => WithdrawRequest[]) withdrawRequests;
        // Total queued withdrawals
        uint256 totalQueuedWithdrawals;
        // Validator tracking
        Validator[] validators;
        // Validator IDs
        uint256[] validatorIds;
        // Withdrawal amounts
        uint256[] withdrawAmounts;
   }

   struct WithdrawRequest {
        uint256 shares;
        uint256 assets;
        uint256 requestTime;
        address receiver;
        bool processed;
        uint256[] requestIds;
        uint256[] validatorIds;
        uint256[] withdrawAmounts;
   }

   struct Validator {
        uint256 id;
        uint256 delegations;
        bool active;
   }
   
   error ZeroDeposit();
   error NoValidators();
   error NoValidatorsWithCapacity();
   error InvalidValidatorIndex();
   error InvalidLiquidityFee();
   error NothingToWithdraw();
   error WithdrawNotReady();

   event Notify(address notifier, uint256 amount);
   event Deposit(uint256 TVL, uint256 amountDeposited);
   event WithdrawQueued(address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256[] validatorIds, uint256[] validatorAmounts);
   event WithdrawProcessed(address indexed owner, address indexed receiver, uint256 shares, uint256 assets);
   event PartialWithdrawProcessed(address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256 requestId, uint256 validatorIndex);
   event ValidatorAdded(uint256 validatorId, uint256 validatorIndex);
   event ValidatorBalanceUpdated(uint256 indexed validatorIndex, uint256 oldBalance, uint256 newBalance);
   event ValidatorStatusChanged(uint256 indexed validatorIndex, bool active);
   event SetBeefyFeeConfig(address indexed oldBeefyFeeConfig, address indexed newBeefyFeeConfig);
   event SetBeefyFeeRecipient(address indexed oldBeefyFeeRecipient, address indexed newBeefyFeeRecipient);
   event SetLiquidityFeeRecipient(address indexed oldLiquidityFeeRecipient, address indexed newLiquidityFeeRecipient);
   event SetLiquidityFee(uint256 oldLiquidityFee, uint256 newLiquidityFee);
   event ChargedFees(uint256 amount, uint256 beefyFee, uint256 liquidityFee);
}