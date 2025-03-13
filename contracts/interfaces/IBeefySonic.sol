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
        // Address of the keeper
        address keeper;
        // Liquidity fee percentage
        uint256 liquidityFee;
        // Total amount of tokens stored
        uint256 storedTotal;
        // Total amount of tokens locked
        uint256 totalLocked;
        // Last time notify was called
        uint256 lastHarvest;
        // Duration to lock tokens
        uint32 lockDuration;
        // Duration to withdraw tokens
        uint32 withdrawDuration;
        // Withdraw request ID
        uint256 requestId;
        // Withdraw ID for SFC request
        uint256 wId;
        // Operator tracking
        mapping(address => mapping(address => bool)) isOperator;
        // Redemption requests
        mapping(address => mapping(uint256 => RedemptionRequest)) pendingRedemptions;
        // Total queued withdrawals
        uint256 totalPendingRedeemAssets;
        // Validator tracking
        Validator[] validators;
        // Validator IDs
        uint256[] validatorIds;
        // Withdrawal amounts
        uint256[] withdrawAmounts;
   }

   struct RedemptionRequest {
        uint256 assets;
        uint256 shares;
        uint32 claimableTimestamp;
        uint256[] requestIds;
        uint256[] validatorIds;
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
   error NotAuthorized();
   error InsufficientBalance();
   error NotClaimableYet();

   event Notify(address notifier, uint256 amount);
   event Deposit(uint256 TVL, uint256 amountDeposited);
   event ClaimedRewards(uint256 amount);
   event WithdrawQueued(address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256[] validatorIds, uint256[] validatorAmounts);
   event WithdrawProcessed(address indexed owner, address indexed receiver, uint256 shares, uint256 assets);
   event PartialWithdrawProcessed(address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256 requestId, uint256 validatorIndex);
   event ValidatorAdded(uint256 validatorId, uint256 validatorIndex);
   event ValidatorBalanceUpdated(uint256 indexed validatorIndex, uint256 oldBalance, uint256 newBalance);
   event ValidatorStatusChanged(uint256 indexed validatorIndex, bool active);
   event BeefyFeeConfigSet(address indexed oldBeefyFeeConfig, address indexed newBeefyFeeConfig);
   event BeefyFeeRecipientSet(address indexed oldBeefyFeeRecipient, address indexed newBeefyFeeRecipient);
   event LiquidityFeeRecipientSet(address indexed oldLiquidityFeeRecipient, address indexed newLiquidityFeeRecipient);
   event LiquidityFeeSet(uint256 oldLiquidityFee, uint256 newLiquidityFee);
   event ChargedFees(uint256 amount, uint256 beefyFee, uint256 liquidityFee);
   event OperatorSet(address indexed owner, address indexed operator, bool approved);
   event LockDurationSet(uint256 oldLockDuration, uint256 newLockDuration);
   event KeeperSet(address indexed oldKeeper, address indexed newKeeper);
   event RedeemRequest(address indexed controller, address indexed owner, uint256 requestId, address indexed caller, uint256 shares);
}