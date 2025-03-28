// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBeefySonic {
    struct BeefySonicStorage {
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
        // Withdraw request ID
        uint256 requestId;
        // Withdraw ID for SFC request
        uint256 wId;
        // Minimum harvest amount
        uint256 minHarvest;
        // Operator tracking
        mapping(address => mapping(address => bool)) isOperator;
        // Redemption requests
        mapping(address => mapping(uint256 => RedemptionRequest)) pendingRedemptions;
        // Pending requests for each owner
        mapping(address => uint256[]) pendingRequests;
        // Validator tracking
        Validator[] validators;
    }

    struct RedemptionRequest {
        uint256 assets;
        uint256 shares;
        uint32 requestTimestamp;
        bool emergency;
        uint256[] withdrawalIds;
        uint256[] validatorIds;
    }

    struct Validator {
        uint256 id;
        uint256 delegations;
        uint256 slashedWId;
        uint256 recoverableAmount;
        uint256 slashedDelegations;
        bool active;
        bool claim;
    }

    error ERC7540AsyncFlow();
    error InvalidLiquidityFee();
    error InvalidValidatorIndex();
    error NoValidators();
    error NoValidatorsWithCapacity();
    error NotAuthorized();
    error NotClaimableYet();
    error NotEnoughRewards();
    error NotOK();
    error NotReadyForHarvest();
    error NothingToWithdraw();
    error ValidatorNotFound();
    error WithdrawError();
    error ZeroDeposit();
    error ZeroAddress();

    event BeefyFeeConfigSet(address indexed oldBeefyFeeConfig, address indexed newBeefyFeeConfig);
    event BeefyFeeRecipientSet(address indexed oldBeefyFeeRecipient, address indexed newBeefyFeeRecipient);
    event ChargedFees(uint256 beefyFee, uint256 liquidityFee);
    event ClaimedRewards(uint256 amount);
    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);
    event LiquidityFeeRecipientSet(address indexed oldLiquidityFeeRecipient, address indexed newLiquidityFeeRecipient);
    event LiquidityFeeSet(uint256 oldLiquidityFee, uint256 newLiquidityFee);
    event LockDurationSet(uint256 oldLockDuration, uint256 newLockDuration);
    event MinHarvestSet(uint256 oldMinHarvest, uint256 newMinHarvest);
    event Notify(address notifier, uint256 amount);
    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 requestId,
        address indexed caller,
        uint256 shares,
        uint32 requestTimestamp
    );
    event SlashedValidatorWithdrawn(uint256 indexed validatorId, uint256 amountRecovered, uint256 loss);
    event ValidatorAdded(uint256 validatorId, uint256 validatorIndex);
    event ValidatorClaimSet(uint256 indexed validatorIndex, bool claim);
    event ValidatorSlashed(uint256 indexed validatorId, uint256 recoverableAmount, uint256 delegations);
    event ValidatorStatusChanged(uint256 indexed validatorIndex, bool active, bool shouldClaim);
    event WithdrawProcessed(address indexed owner, address indexed receiver, uint256 shares, uint256 assets);

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
    /// @param shouldClaim Whether the validator should claim
    function setValidatorStatus(uint256 validatorIndex, bool active, bool shouldClaim) external;

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
