// SPDX-License-Identifier: MIT
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
   error ERC7540AsyncFlow();

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

   /// @notice Request a redeem, interface of EIP - 7540 https://eips.ethereum.org/EIPS/eip-7540
   /// @param shares Amount of shares to redeem
   /// @param controller Controller address
   /// @param owner Owner address
   /// @return requestId Request ID
   function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

   /// @notice Get the pending redeem request
   /// @param _requestId ID of the redeem request
   /// @param _controller Controller address
   /// @return shares Amount of shares
   function pendingRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 shares);

   /// @notice Get the claimable redeem request
   /// @param _requestId ID of the redeem request
   /// @param _controller Controller address
   /// @return shares Amount of shares
   function claimableRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 shares);

   /// @notice Get the price per full share
   /// @return pricePerFullShare Price per full share
   function getPricePerFullShare() external view returns (uint256);

   /// @notice Notify the yield to start vesting
   function harvest() external;

   /// @notice Remaining locked profit after a notification
   /// @return locked Amount remaining to be vested
   function lockedProfit() external view returns (uint256 locked);

   /// @notice Add a new validator
   /// @param validatorId ID of the validator
   function addValidator(uint256 validatorId) external;

   /// @notice Set a validator's active status
   /// @param validatorIndex Index of the validator
   /// @param active Whether the validator is active
   function setValidatorActive(uint256 validatorIndex, bool active) external;

   /// @notice Set an operator to finalize the claim of the request to withdraw
   /// @param operator Address of the operator
   /// @param approved Whether the operator is approved
   function setOperator(address operator, bool approved) external returns (bool);

   /// @notice Set the Beefy fee recipient
   /// @param _beefyFeeRecipient Address of the new Beefy fee recipient
   function setBeefyFeeRecipient(address _beefyFeeRecipient) external;

   /// @notice Set the Beefy fee configuration
   /// @param _beefyFeeConfig Address of the new Beefy fee configuration
   function setBeefyFeeConfig(address _beefyFeeConfig) external;

   /// @notice Set the liquidity fee recipient
   /// @param _liquidityFeeRecipient Address of the new liquidity fee recipient    
   function setLiquidityFeeRecipient(address _liquidityFeeRecipient) external;

   /// @notice Set the liquidity fee percentage
   /// @param _liquidityFee Percentage of the fee
   function setLiquidityFee(uint256 _liquidityFee) external;

   /// @notice Set the keeper
   /// @param _keeper Address of the new keeper
   function setKeeper(address _keeper) external;

   /// @notice Set the lock duration
   /// @param _lockDuration Duration to lock tokens
   function setLockDuration(uint32 _lockDuration) external;

   /// @notice Pause the contract only callable by the owner or keeper
   function pause() external;

   /// @notice Unpause the contract only callable by the owner
   function unpause() external;
}