// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Upgradeable, ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IBeefySonic} from "./interfaces/IBeefySonic.sol";
import {IWrappedNative} from "./interfaces/IWrappedNative.sol";
import {ISFC} from "./interfaces/ISFC.sol";
import {IConstantsManager} from "./interfaces/IConstantsManager.sol";
import {IFeeConfig} from "./interfaces/IFeeConfig.sol";
import {BeefySonicStorageUtils} from "../contracts/BeefySonicStorageUtils.sol";

/// @title BeefySonic
/// @author Beefy, weso
/// @dev Liquid staked interest bearing version of the Sonic token
contract BeefySonic is 
    IBeefySonic, 
    UUPSUpgradeable, 
    ERC20Upgradeable, 
    ERC20PermitUpgradeable,
    ERC4626Upgradeable, 
    OwnableUpgradeable, 
    PausableUpgradeable,
    BeefySonicStorageUtils 
{
    using SafeERC20 for IERC20;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }  

    /// @notice Initialize the contract 
    /// @param _want Address of the want token
    /// @param _stakingContract Address of the staking contract
    /// @param _beefyFeeRecipient Address of the Beefy fee recipient
    /// @param _keeper Address of the keeper
    /// @param _beefyFeeConfig Address of the Beefy fee configuration
    /// @param _liquidityFeeRecipient Address of the liquidity fee recipient
    /// @param _liquidityFee Liquidity fee percentage
    /// @param _name Name of the staked token
    /// @param _symbol Symbol of the staked token
    function initialize(
        address _want, 
        address _stakingContract,
        address _beefyFeeRecipient,
        address _keeper,
        address _beefyFeeConfig,
        address _liquidityFeeRecipient, 
        uint256 _liquidityFee,
        string memory _name,
        string memory _symbol
    ) public initializer {
        __UUPSUpgradeable_init();
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __ERC4626_init(IERC20(_want));
        __Ownable_init(msg.sender);
        __Pausable_init();

        // Limit the liquidity fee to 10%
        if (_liquidityFee > 0.1e18) revert InvalidLiquidityFee();

        BeefySonicStorage storage $ = getBeefySonicStorage();
        $.want = _want;
        $.stakingContract = _stakingContract;
        $.beefyFeeRecipient = _beefyFeeRecipient;
        $.keeper = _keeper;
        $.beefyFeeConfig = _beefyFeeConfig;
        $.liquidityFeeRecipient = _liquidityFeeRecipient;
        $.liquidityFee = _liquidityFee;
        $.lockDuration = 1 days;
        $.withdrawDuration = 14 days;
        $.minHarvest = 1e6;
        $.minWithdraw = 1e18;
        $.requestId++;
    }

    /// @notice Deposit assets into the vault
    /// @param caller Address of the caller
    /// @param receiver Address of the receiver
    /// @param assets Amount of assets to deposit
    /// @param shares Amount of shares to mint
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override whenNotPaused {
        BeefySonicStorage storage $ = getBeefySonicStorage(); 

        // We dont allow deposits of 0
        if (assets == 0 || shares == 0) revert ZeroDeposit();

        // Delegate assets to the validator only if a single validator can handle the deposit amount
        uint256 validatorIndex = _getValidatorToDeposit(assets);  

        // Update validator delegations and stored total
        $.validators[validatorIndex].delegations += assets;
        $.storedTotal += assets;

        // Transfer tokens and mint shares
        super._deposit(caller, receiver, assets, shares);

        // Withdraw assets from the wrapped native token
        IWrappedNative($.want).withdraw(assets);

        // Delegate assets to the validator only if a single validator can handle the deposit amount
        ISFC($.stakingContract).delegate{value: assets}($.validators[validatorIndex].id);

        emit Deposit(totalAssets(), assets);
    }

    /// @notice Get the validator to deposit to
    /// @param _amount Amount of assets to deposit
    /// @return validatorId ID of the validator
    function _getValidatorToDeposit(uint256 _amount) internal returns (uint256 validatorId) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        
        // Ensure we have validators
        if($.validators.length == 0) revert NoValidators();

        // Get max delegated ratio from the constants manager via the SFC
        uint256 maxDelegatedRatio = IConstantsManager(ISFC($.stakingContract).constsAddress()).maxDelegatedRatio();

        // Loop and try to deposit into the first validator in the set with capacity
        for(uint256 i; i < $.validators.length; ++i) {
            Validator memory validator = $.validators[i];

            // Check if the validator is slashed and mark it as inactive if it is
            bool isSlashed = ISFC($.stakingContract).isSlashed(validator.id);
            if (isSlashed) {
                $.validators[i].active = false;
                continue;
            }

            // Check if the validator is active
            if(validator.active) {
                uint256 selfStake = ISFC($.stakingContract).getSelfStake(validator.id);
                (, uint256 receivedStake,,,,,) = ISFC($.stakingContract).getValidator(validator.id);
                
                // Validator delegated capacity is maxDelegatedRatio times the self-stake
                uint256 delegatedCapacity = selfStake * maxDelegatedRatio / 1e18;
                
                // Check if the validator has available capacity
                if (delegatedCapacity >= (receivedStake + _amount)) return i;
            }
        }

        // No validators with capacity
        revert NoValidatorsWithCapacity();
    }

    /// @notice Request a redeem, interface of EIP - 7540 https://eips.ethereum.org/EIPS/eip-7540
    /// @param shares Amount of shares to redeem
    /// @param controller Controller address
    /// @param owner Owner address
    /// @return requestId Request ID
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        // Ensure the owner is the caller or an authorized operator
        if (owner != msg.sender || !$.isOperator[owner][msg.sender]) revert NotAuthorized();

        // Ensure the minimum withdrawal amount is met
        if (shares < $.minWithdraw) revert MinWithdrawNotMet();

        // Convert shares to assets
        uint256 assets = convertToAssets(shares);

        // Burn shares of the owner will revert if shares is > balanceOf(owner)
        _burn(owner, shares);

        requestId = $.requestId;
        $.requestId++;

        // Get validators to withdraw from will be multiple if the amount is too large
        (uint256[] memory validatorIds, uint256[] memory amounts) = _getValidatorsToWithdraw(assets);

        // Create request IDs
        uint256[] memory requestIds = new uint256[](validatorIds.length);

        // Undelegate assets from the validators
        for (uint256 i; i < validatorIds.length; ++i) {
            // Get the next wId, we want this to be unique for each request
            uint256 wId = $.wId;
            requestIds[i] = wId;

            // Undelegate assets from the validator
            ISFC($.stakingContract).undelegate(validatorIds[i], wId, amounts[i]);

            // Update validator delegations and stored total
            $.validators[i].delegations -= amounts[i];
            $.storedTotal -= amounts[i];

            // Increment wId
            $.wId++;
        }

        uint32 claimableTimestamp = uint32(block.timestamp) + $.withdrawDuration;

        // Store the request
        $.pendingRedemptions[owner][requestId] =
            RedemptionRequest({
                assets: assets,
                shares: shares,
                claimableTimestamp: claimableTimestamp,
                requestIds: requestIds,
                validatorIds: validatorIds
            });
        
        // Add the request ID to the owner's pending requests
        $.pendingRequests[owner].push(requestId);

        // Update total pending redeem assets
        $.totalPendingRedeemAssets += assets;

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares, claimableTimestamp);
        return requestId;
    }

    /// @notice Get validators to withdraw from
    /// @param _assets Amount of assets to withdraw
    /// @return _validatorIds Array of validator IDs
    /// @return _withdrawAmounts Array of withdraw amounts
    function _getValidatorsToWithdraw(uint256 _assets) internal returns (uint256[] memory _validatorIds, uint256[] memory _withdrawAmounts) {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        uint256 remaining = _assets;

        uint256 currentEpoch = ISFC($.stakingContract).currentEpoch();

        // loop backwards in the validators array withdraw from newest validator first
        for (uint256 i = $.validators.length; i > 0; i--) {
            Validator storage validator = $.validators[i-1];

            // 2 withdrawals in same epoch will revert this skips a validator with a withdraw in same epoch
            if (validator.lastUndelegateEpoch == currentEpoch) continue;

            if (remaining > validator.delegations) {
                $.validatorIds.push(validator.id);
                $.withdrawAmounts.push(validator.delegations);
                remaining -= validator.delegations;
                validator.lastUndelegateEpoch = currentEpoch;
            } else {
                $.validatorIds.push(validator.id);
                $.withdrawAmounts.push(remaining);
                remaining = 0;
                validator.lastUndelegateEpoch = currentEpoch;
                break;
            }
        }

        if (remaining > 0) revert WithdrawError();

        // We do this because we dont know the size of our array and cant push to memory so we store them and write to memory then delete
        _validatorIds = $.validatorIds;
        _withdrawAmounts = $.withdrawAmounts;
        delete $.validatorIds;
        delete $.withdrawAmounts;
    }
    
    /// @notice Withdraw assets from the vault
    /// @param _requestId Request ID of the withdrawal
    /// @param _receiver Address to receive the assets
    /// @param _controller Controller address
    /// @return shares Amount of shares withdrawn
    function withdraw(uint256 _requestId, address _receiver, address _controller)
        public
        virtual
        override
        returns (uint256 shares)
    {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        // Ensure the controller is the caller or an authorized operator
        if(!(_controller == msg.sender || !$.isOperator[_controller][msg.sender])) revert NotAuthorized();
       
        RedemptionRequest storage request = $.pendingRedemptions[_controller][_requestId];
        
        // Ensure the request is claimable
        if (request.claimableTimestamp > block.timestamp) revert NotClaimableYet();

        // Update total pending redeem assets
        $.totalPendingRedeemAssets -= request.assets;

        shares = request.shares;

        // Withdraw assets from the SFC
        uint256 amountWithdrawn = _withdrawFromSFC(_requestId, _controller);
        _withdraw(msg.sender, _receiver, _controller, amountWithdrawn, shares);

        // Delete the request to not allow double withdrawal
        delete $.pendingRedemptions[_controller][_requestId];
        _removeRequest(_controller, _requestId);
    }

    /// @notice Redeem shares for assets
    /// @param _requestId Request ID of the withdrawal
    /// @param _receiver Address to receive the assets
    /// @param _controller Controller address
    /// @return assets Amount of assets redeemed
    function redeem(uint256 _requestId, address _receiver, address _controller)
        public
        virtual
        override
        returns (uint256 assets)
    {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        // Ensure the controller is the caller or an authorized operator
        if(!(_controller == msg.sender || !$.isOperator[_controller][msg.sender])) revert NotAuthorized();

        RedemptionRequest storage request = $.pendingRedemptions[_controller][_requestId];

        // Ensure the request is claimable
        if (request.claimableTimestamp > block.timestamp) revert NotClaimableYet();

        // Update total pending redeem assets   
        $.totalPendingRedeemAssets -= request.assets;

        // Withdraw assets from the SFC
        uint256 amountWithdrawn = _withdrawFromSFC(_requestId, _controller);
        _withdraw(msg.sender, _receiver, _controller, amountWithdrawn, request.shares);

        // Delete the request to not allow double withdrawal
        delete $.pendingRedemptions[_controller][_requestId];
        _removeRequest(_controller, _requestId);
        
        return amountWithdrawn;
    }

    /// @notice Remove a request from the pending requests
    /// @param _controller Controller address
    /// @param _requestId Request ID
    function _removeRequest(address _controller, uint256 _requestId) internal {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        // Get the pending requests array for the controller
        uint256[] storage pendingRequests = $.pendingRequests[_controller];
        
        // If the array is empty, nothing to do
        if (pendingRequests.length == 0) return;
        
        // Find the index of the request ID
        uint256 index = type(uint256).max; // Invalid index to start
        for (uint256 i = 0; i < pendingRequests.length; i++) {
            if (pendingRequests[i] == _requestId) {
                index = i;
                break;
            }
        }
        
        // If the request ID was not found, nothing to do
        if (index == type(uint256).max) return;
        
        // If it's the last element, just pop it
        if (index == pendingRequests.length - 1) {
            pendingRequests.pop();
            return;
        }
        
        // Otherwise, move the last element to the position of the removed element and pop
        pendingRequests[index] = pendingRequests[pendingRequests.length - 1];
        pendingRequests.pop();
    }

    /// @notice Withdraw assets from the SFC
    /// @param _requestId Request ID of the withdrawal
    /// @param _controller Controller address
    /// @return amountWithdrawn Amount of assets withdrawn
    function _withdrawFromSFC(uint256 _requestId, address _controller) internal returns (uint256 amountWithdrawn) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        RedemptionRequest storage request = $.pendingRedemptions[_controller][_requestId];
        
        // We fetch the before and after balance in case of slashing and we end up with less assets than desired
        uint256 before = address(this).balance;

        // Withdraw assets from the validators
        for (uint256 j = 0; j < request.requestIds.length; j++) {
            uint256 validatorId = request.validatorIds[j];
            uint256 requestId = request.requestIds[j];

            // Check if the validator is slashed
            bool isSlashed = ISFC($.stakingContract).isSlashed(validatorId);
            if (isSlashed) {
                // update validator to not active find index
                uint256 index = _getValidatorIndex(validatorId);
                $.validators[index].active = false;
                // If the validator is slashed, we need to make sure we get the refund if more than 0
                uint256 refundAmount = ISFC($.stakingContract).slashingRefundRatio(validatorId);
                if (refundAmount > 0) {
                    ISFC($.stakingContract).withdraw(validatorId, requestId);
                }
            } else {
                // If the validator is not slashed, we can withdraw the assets
                ISFC($.stakingContract).withdraw(validatorId, requestId);
            }
        }

        // Calculate the amount withdrawn
        amountWithdrawn = address(this).balance - before;
    }

    /// @notice Internal withdraw function
    /// @param caller Caller address
    /// @param receiver Receiver address
    /// @param controller Controller address
    /// @param assets Amount of assets to withdraw
    /// @param shares Amount of shares to withdraw
    function _withdraw(
        address caller,
        address receiver,
        address controller,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if (caller != controller) {
            _spendAllowance(controller, caller, shares);
        }

        // Deposit raw S into the wrapper
        IWrappedNative($.want).deposit{value: assets}();

        // Transfer the assets to the receiver
        IERC20($.want).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, controller, assets, shares);
    }

    /// @notice Get the pending redeem request
    /// @param _requestId ID of the redeem request
    /// @param _controller Controller address
    /// @return shares Amount of shares
    function pendingRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 shares) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        RedemptionRequest storage request = $.pendingRedemptions[_controller][_requestId];

        // Return the shares if the request is pending
        if (request.claimableTimestamp > block.timestamp) return request.shares;
        return 0;
    }

    /// @notice Get the claimable redeem request
    /// @param _requestId ID of the redeem request
    /// @param _controller Controller address
    /// @return shares Amount of shares
    function claimableRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 shares) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        RedemptionRequest storage request = $.pendingRedemptions[_controller][_requestId];

        // Return the shares if the request is claimable
        if (request.claimableTimestamp <= block.timestamp) return request.shares;
        return 0;
    }

    /// @notice Get the pending redeem requests for a user
    /// @param _controller Controller address
    /// @return pendingRequests Array of pending requests
    function userPendingRedeemRequests(address _controller) external view returns (uint256[] memory) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        return $.pendingRequests[_controller];
    }

    /// @notice Preview withdraw always reverts for async flows
    function previewWithdraw(uint256) public pure virtual override returns (uint256) {
        revert ERC7540AsyncFlow();
    }

    /// @notice Preview redeem always reverts for async flows
    function previewRedeem(uint256) public pure virtual override returns (uint256) {
        revert ERC7540AsyncFlow();
    }

    /// @notice Get the price per full share
    /// @return pricePerFullShare Price per full share
    function getPricePerFullShare() external view returns (uint256) {
        return convertToAssets(1e18);
    }

    /// @notice Override the decimals function to match underlying decimals
    /// @return _decimals Decimals of the underlying token
    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
        return ERC4626Upgradeable.decimals();
    }
   
    /// @notice Notify the yield to start vesting
    function harvest() external whenNotPaused {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        // We just return if the last harvest was within the lock duration to prevent ddos 
        if (block.timestamp - $.lastHarvest <= $.lockDuration) revert NotReadyForHarvest();

        // Claim pending rewards
        uint256 beforeBal = address(this).balance;
        _claim();
        uint256 claimed = address(this).balance - beforeBal;
        emit ClaimedRewards(claimed);

        // Check if there is enough rewards
        if (claimed < $.minHarvest) revert NotEnoughRewards();

        // Charge fees
        _chargeFees(claimed);

        // Balance of Native on the contract this includes Sonic after fees and donations
        uint256 contractBalance = address(this).balance;

        // Update stored total and total locked
        $.totalLocked = lockedProfit() + contractBalance;
        $.storedTotal += contractBalance;
        $.lastHarvest = block.timestamp;

        // Get validator to deposit
        uint256 validatorId = _getValidatorToDeposit(contractBalance);

        // Get validator from storage
        Validator storage validator = $.validators[validatorId];

        // Update delegations
        validator.delegations += contractBalance;

        // Delegate assets to the validator only if a single validator can handle the deposit amount
        ISFC($.stakingContract).delegate{value: contractBalance}(validator.id);

        emit Notify(msg.sender, contractBalance);
        
    }

    /// @notice Claim pending rewards from validators
    function _claim() internal {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        for (uint256 i = 0; i < $.validators.length; i++) {
            Validator storage validator = $.validators[i];
            if (validator.active) {
                // Claim rewards from the staking contract
                uint256 pending = ISFC($.stakingContract).pendingRewards(address(this), validator.id);
                if (pending > 0) ISFC($.stakingContract).claimRewards(validator.id);
            }
        }
    }

    /// @notice Charge fees
    /// @param amount Amount of assets to charge
    function _chargeFees(uint256 amount) internal {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        uint256 beefyFee = amount * IFeeConfig($.beefyFeeConfig).getFees(address(this)).total / 1e18;
        uint256 liquidityFee = amount * $.liquidityFee / 1e18;

        IWrappedNative($.want).deposit{value: liquidityFee + beefyFee}();
        IERC20($.want).safeTransfer($.beefyFeeRecipient, beefyFee);
        IERC20($.want).safeTransfer($.liquidityFeeRecipient, liquidityFee);

        emit ChargedFees(amount, beefyFee, liquidityFee);
    }

    /// @notice Get validator index by validator ID
    /// @param validatorId Validator ID
    /// @return index Index of the validator
    function _getValidatorIndex(uint256 validatorId) internal view returns (uint256) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        for (uint256 i = 0; i < $.validators.length; i++) {
            if ($.validators[i].id == validatorId) return i;
        }
        revert ValidatorNotFound();
    }

    /// @notice Remaining locked profit after a notification
    /// @return locked Amount remaining to be vested
    function lockedProfit() public view returns (uint256 locked) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if ($.lockDuration == 0) return 0;
        uint256 elapsed = block.timestamp - $.lastHarvest;
        uint256 remaining = elapsed < $.lockDuration ? $.lockDuration - elapsed : 0;
        locked = $.totalLocked * remaining / $.lockDuration;
    }

    /// @notice Total assets on this contract
    /// @return total Total amount of assets
    function totalAssets() public view override returns (uint256 total) {
        total = getBeefySonicStorage().storedTotal - lockedProfit();
    }

    /// @notice Add a new validator
    /// @param validatorId ID of the validator
    function addValidator(uint256 validatorId) external onlyOwner {
        require(validatorId != 0, "BeefySonic: validator ID cannot be zero");
        
        BeefySonicStorage storage $ = getBeefySonicStorage();
        
        // Create new validator
        Validator memory validator = Validator({
            id: validatorId,
            delegations: 0,
            lastUndelegateEpoch: 0,
            active: true
        });
        
        // Add to validators array
        uint256 validatorIndex = $.validators.length;
        $.validators.push(validator);
        
        emit ValidatorAdded(validatorId, validatorIndex);
    }

    /// @notice Get the number of validators
    /// @return _length Number of validators
    function validatorsLength() external view returns (uint256) {
        return getBeefySonicStorage().validators.length;
    }

    /// @notice Get a validator
    /// @param validatorIndex Index of the validator
    /// @return validator Validator struct
    function validatorByIndex(uint256 validatorIndex) external view returns (Validator memory) {
        return getBeefySonicStorage().validators[validatorIndex];
    }

    /// @notice Get the want token
    /// @return want Address of the want token
    function want() external view returns (address) {
        return getBeefySonicStorage().want;
    }

    /// @notice Set a validator's active status
    /// @param validatorIndex Index of the validator
    /// @param active Whether the validator is active
    function setValidatorActive(uint256 validatorIndex, bool active) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        
        if (validatorIndex >= $.validators.length) revert InvalidValidatorIndex();
        
        $.validators[validatorIndex].active = active;
        
        emit ValidatorStatusChanged(validatorIndex, active);
    }

    /// @notice Set an operator to finalize the claim of the request to withdraw
    /// @param operator Address of the operator
    /// @param approved Whether the operator is approved
    function setOperator(address operator, bool approved) public returns (bool) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        $.isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @notice Set the Beefy fee recipient
    /// @param _beefyFeeRecipient Address of the new Beefy fee recipient
    function setBeefyFeeRecipient(address _beefyFeeRecipient) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit BeefyFeeRecipientSet($.beefyFeeRecipient, _beefyFeeRecipient);
        $.beefyFeeRecipient = _beefyFeeRecipient;
    }

    /// @notice Set the Beefy fee configuration
    /// @param _beefyFeeConfig Address of the new Beefy fee configuration
    function setBeefyFeeConfig(address _beefyFeeConfig) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit BeefyFeeConfigSet($.beefyFeeConfig, _beefyFeeConfig);
        $.beefyFeeConfig = _beefyFeeConfig;
    }

    /// @notice Set the liquidity fee recipient
    /// @param _liquidityFeeRecipient Address of the new liquidity fee recipient    
    function setLiquidityFeeRecipient(address _liquidityFeeRecipient) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit LiquidityFeeRecipientSet($.liquidityFeeRecipient, _liquidityFeeRecipient);
        $.liquidityFeeRecipient = _liquidityFeeRecipient;
    }

    /// @notice Set the liquidity fee percentage
    /// @param _liquidityFee Percentage of the fee
    function setLiquidityFee(uint256 _liquidityFee) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit LiquidityFeeSet($.liquidityFee, _liquidityFee);
        if (_liquidityFee > 0.1e18) revert InvalidLiquidityFee();
        $.liquidityFee = _liquidityFee;
    }

    /// @notice Set the keeper
    /// @param _keeper Address of the new keeper
    function setKeeper(address _keeper) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        $.keeper = _keeper;
        emit KeeperSet($.keeper, _keeper);
    }

    /// @notice Set the lock duration
    /// @param _lockDuration Duration of the lock
    function setLockDuration(uint32 _lockDuration) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        $.lockDuration = _lockDuration;
        emit LockDurationSet($.lockDuration, _lockDuration);
    }

    /// @notice Set the minimum withdrawal amount
    /// @param _minWithdraw Minimum withdrawal amount
    function setMinWithdraw(uint256 _minWithdraw) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        $.minWithdraw = _minWithdraw;
        emit MinWithdrawSet($.minWithdraw, _minWithdraw);
    }

    /// @notice Pause the contract only callable by the owner or keeper
    function pause() external {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if (msg.sender != $.keeper && msg.sender != owner()) revert NotAuthorized();
        _pause();
    }

    /// @notice Unpause the contract only callable by the owner
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Function to authorize upgrades, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Receive function for receiving Native Sonic
    receive() external payable {}
}
