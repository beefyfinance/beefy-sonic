// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ERC20Upgradeable,
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
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
        __UUPSUpgradeable_init_unchained();
        __ERC20_init_unchained(_name, _symbol);
        __ERC20Permit_init(_name);
        __ERC4626_init_unchained(IERC20(_NoZeroAddress(_want)));
        __Ownable_init_unchained(msg.sender);
        __Pausable_init_unchained();

        // Limit the liquidity fee to 10%
        if (_liquidityFee > 0.1e18) revert InvalidLiquidityFee();

        BeefySonicStorage storage $ = getBeefySonicStorage();
        $.stakingContract = _NoZeroAddress(_stakingContract);
        $.beefyFeeRecipient = _NoZeroAddress(_beefyFeeRecipient);
        $.keeper = _NoZeroAddress(_keeper);
        $.beefyFeeConfig = _NoZeroAddress(_beefyFeeConfig);
        $.liquidityFeeRecipient = _NoZeroAddress(_liquidityFeeRecipient);
        $.liquidityFee = _liquidityFee;
        $.lockDuration = 1 days;
        $.minHarvest = 1e6;
        $.requestId++;
    }

    /// @notice Check if the caller is an authorized operator
    /// @param _controller Controller address
    function _isAuthorizedOperator(address _controller) private view {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if (_controller != msg.sender && !$.isOperator[_controller][msg.sender]) revert NotAuthorized();
    }

    /// @notice Deposit assets into the vault
    /// @param _caller Address of the caller
    /// @param _receiver Address of the receiver
    /// @param _assets Amount of assets to deposit
    /// @param _shares Amount of shares to mint
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares)
        internal
        override
        whenNotPaused
    {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if ($.slashedValidators > 0) revert SlashNotRealized();
        _NoZeroAddress(_receiver);

        // We dont allow deposits of 0
        if (_assets == 0 || _shares == 0) revert ZeroDeposit();

        // Delegate assets to the validator only if a single validator can handle the deposit amount
        uint256 validatorIndex = _getValidatorToDeposit(_assets);
        if (validatorIndex == type(uint256).max) revert NoValidatorsWithCapacity();

        // Update validator delegations and stored total
        $.validators[validatorIndex].delegations += _assets;
        $.storedTotal += _assets;

        // Transfer tokens and mint shares
        super._deposit(_caller, _receiver, _assets, _shares);

        // Withdraw assets from the wrapped native token
        IWrappedNative(asset()).withdraw(_assets);

        // Delegate assets to the validator only if a single validator can handle the deposit amount
        ISFC($.stakingContract).delegate{value: _assets}($.validators[validatorIndex].id);
    }

    /// @notice Get the validator to deposit to
    /// @param _amount Amount of assets to deposit
    /// @return validatorId ID of the validator
    function _getValidatorToDeposit(uint256 _amount) private returns (uint256 validatorId) {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        // Ensure we have validators
        if ($.validators.length == 0) revert NoValidators();

        // Get max delegated ratio from the constants manager via the SFC
        uint256 _maxDelegatedRatio = maxDelegatedRatio();

        // Loop and try to deposit into the first validator in the set with capacity
        for (uint256 i; i < $.validators.length; ++i) {
            Validator memory validator = $.validators[i];

            if (!validator.active) continue;

            // Check if the validator is ok
            (bool isOk,) = _validatorStatus(validator.id);
            if (!isOk) {
                if (isSlashed(validator.id)) revert SlashNotRealized();
                _setValidatorStatus(i, false, true);

                continue;
            }

            uint256 delegatedCapacity = _delegatedCapacity(validator.id, _maxDelegatedRatio);

            // Check if the validator has available capacity
            if (delegatedCapacity >= _amount) return i;
        }

        // No validators with capacity so issue a large number to not collide
        validatorId = type(uint256).max;
    }

    /// @notice Request a redeem with emergency flag
    /// @param _shares Amount of shares to redeem
    /// @param _controller Controller address
    /// @param _owner Owner address
    /// @param _emergency Emergency flag
    /// @return requestId Request ID
    function requestRedeem(uint256 _shares, address _controller, address _owner, bool _emergency)
        external
        returns (uint256 requestId)
    {
        return _requestRedeem(_shares, _controller, _owner, _emergency);
    }

    /// @notice Request a redeem, interface of EIP - 7540 https://eips.ethereum.org/EIPS/eip-7540
    /// @param _shares Amount of shares to redeem
    /// @param _controller Controller address
    /// @param _owner Owner address
    /// @return requestId Request ID
    function requestRedeem(uint256 _shares, address _controller, address _owner) external returns (uint256 requestId) {
        return _requestRedeem(_shares, _controller, _owner, false);
    }

    /// @notice Request a redeem, interface of EIP - 7540 https://eips.ethereum.org/EIPS/eip-7540
    /// @param _shares Amount of shares to redeem
    /// @param _controller Controller address
    /// @param _owner Owner address
    /// @return requestId Request ID
    function _requestRedeem(uint256 _shares, address _controller, address _owner, bool _emergency)
        private
        returns (uint256 requestId)
    {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        if (allowance(_owner, _controller) >= _shares)  _spendAllowance(_owner, _controller, _shares);
        // Ensure the owner is the caller or an authorized operator
        else _isAuthorizedOperator(_owner);

        // Convert shares to assets
        uint256 assets = convertToAssets(_shares);

        // Burn shares of the owner will revert if shares is > balanceOf(owner)
        _burn(_owner, _shares);

        requestId = $.requestId;
        $.requestId++;
        $.storedTotal -= assets;

        // Get validators to withdraw from will be multiple if the amount is too large
        (uint256[] memory validatorIds, uint256[] memory amounts) = _getValidatorsToWithdraw(assets, _emergency);

        // Create withdrawal IDs
        uint256[] memory withdrawalIds = new uint256[](validatorIds.length);

        // Undelegate assets from the validators
        for (uint256 i; i < validatorIds.length; ++i) {
            uint256 validatorId = validatorIds[i];
            // Get the next wId, we want this to be unique for each request
            uint256 wId = $.wId;
            withdrawalIds[i] = wId;

            // Undelegate assets from the validator
            ISFC($.stakingContract).undelegate(validatorId, wId, amounts[i]);

            // Get the validator index by ID before updating
            uint256 validatorIndex = _getValidatorIndex(validatorId);

            // Update validator delegations and stored total
            $.validators[validatorIndex].delegations -= amounts[i];

            // Increment wId
            $.wId++;
        }

        uint32 requestTimestamp = uint32(block.timestamp);

        // Store the request
        $.pendingRedemptions[_controller][requestId] = RedemptionRequest({
            assets: assets,
            shares: _shares,
            requestTimestamp: requestTimestamp,
            emergency: _emergency,
            withdrawalIds: withdrawalIds,
            validatorIds: validatorIds
        });

        // Add the request ID to the owner's pending requests
        $.pendingRequests[_controller].push(requestId);

        emit RedeemRequest(_controller, _owner, requestId, msg.sender, _shares, requestTimestamp);
        return requestId;
    }

    /// @notice Get validators to withdraw from
    /// @param _assets Amount of assets to withdraw
    /// @param _emergency Emergency flag
    /// @return _validatorIds Array of validator IDs
    /// @return _withdrawAmounts Array of withdraw amounts
    function _getValidatorsToWithdraw(uint256 _assets, bool _emergency)
        private
        view
        returns (uint256[] memory _validatorIds, uint256[] memory _withdrawAmounts)
    {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        uint256 remaining = _assets;
        uint256[] memory validatorIds = new uint256[]($.validators.length);
        uint256[] memory withdrawAmounts = new uint256[]($.validators.length);
        uint256 currentIndex = 0;

        /// Loop and look to see if any validator is slashed, if they are and have enough delegations we allow a request to process in emergency mode
        for (uint256 i; i < $.validators.length; ++i) {
            Validator storage validator = $.validators[i];
            uint256 validatorId = validator.id;
            uint256 delegations = validator.delegations;
            if (isSlashed(validatorId)) {
                if (delegations == 0) continue;
                // brick redeem requests unless via emergency
                if (!_emergency) revert WithdrawError();

                if (remaining <= delegations) {
                    _validatorIds = new uint256[](1);
                    _withdrawAmounts = new uint256[](1);
                    _validatorIds[0] = validatorId;
                    _withdrawAmounts[0] = remaining;
                    return (_validatorIds, _withdrawAmounts);
                }

                // If we dont have enough delegations from the slashed validator we just revert until we can socialize the loss
                revert WithdrawError();
            }
        }

        // loop backwards in the validators array withdraw from newest validator first
        for (uint256 j = $.validators.length; j > 0; j--) {
            Validator storage validator = $.validators[j - 1];
            uint256 validatorId = validator.id;
            uint256 delegations = validator.delegations;

            if (delegations == 0) continue;

            if (remaining > delegations) {
                validatorIds[currentIndex] = validatorId;
                withdrawAmounts[currentIndex] = delegations;
                remaining -= delegations;
                currentIndex++;
            } else {
                validatorIds[currentIndex] = validatorId;
                withdrawAmounts[currentIndex] = remaining;
                remaining = 0;
                currentIndex++;
                break;
            }
        }

        if (remaining > 0) revert WithdrawError();

        _validatorIds = new uint256[](currentIndex);
        _withdrawAmounts = new uint256[](currentIndex);

        for (uint256 i; i < currentIndex; ++i) {
            _validatorIds[i] = validatorIds[i];
            _withdrawAmounts[i] = withdrawAmounts[i];
        }
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
        (, shares) = _processWithdraw(_requestId, _receiver, _controller, false);
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
        (assets,) = _processWithdraw(_requestId, _receiver, _controller, false);
    }

    /// @notice Emergency withdraw assets from the vault
    /// @param _requestId Request ID of the withdrawal
    /// @param _receiver Address to receive the assets
    /// @param _controller Controller address
    /// @return assets Amount of assets redeemed
    function emergencyWithdraw(uint256 _requestId, address _receiver, address _controller)
        external
        returns (uint256 assets)
    {
        (assets,) = _processWithdraw(_requestId, _receiver, _controller, true);
    }

    /// @notice Check for slashed validators and undelegate
    /// @dev This function is used to undelegate assets from slashed validators
    function checkForSlashedValidatorsAndUndelegate(uint256 validatorIndex) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        Validator storage validator = $.validators[validatorIndex];
        uint256 validatorId = validator.id;
        uint256 delegations = validator.delegations;

        // Check if the validator is slashed
        if (isSlashed(validatorId)) {
            // create a withdraw ID
            uint256 wId = $.wId;
            uint256 refundRatio = slashingRefundRatio(validatorId);
            uint256 recoverableAmount = 0;

            if (refundRatio > 0) {
                recoverableAmount = delegations * refundRatio / 1e18;
                if (recoverableAmount > 0) {
                    ISFC($.stakingContract).undelegate(validatorId, wId, delegations);
                    $.wId++;
                }
            }

            emit ValidatorSlashed(validatorId, recoverableAmount, delegations);
            validator.slashedDelegations = delegations;
            validator.slashedWId = wId;
            validator.delegations = 0;
            validator.active = false;

            $.slashedValidators++;
        }
    }

    /// @notice Complete the withdrawal of a slashed validator
    /// @param validatorIndex Index of the validator
    function completeSlashedValidatorWithdraw(uint256 validatorIndex)
        external
        onlyOwner
        returns (uint256 amountRecovered)
    {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        Validator storage validator = $.validators[validatorIndex];

        uint256 refundRatio = slashingRefundRatio(validator.id);
        uint256 recoverableAmount = 0;
        if (refundRatio > 0) recoverableAmount = validator.slashedDelegations * refundRatio / 1e18;

        if (recoverableAmount > 0) {
            uint256 before = address(this).balance;
            ISFC($.stakingContract).withdraw(validator.id, validator.slashedWId);
            amountRecovered = address(this).balance - before;

            // deposit the recovered amount to another validator
            uint256 depositValidatorIndex = _getValidatorToDeposit(amountRecovered);
            if (depositValidatorIndex == type(uint256).max) revert NoValidatorsWithCapacity();
            $.validators[depositValidatorIndex].delegations += amountRecovered;
            ISFC($.stakingContract).delegate{value: amountRecovered}($.validators[depositValidatorIndex].id);
        }

        uint256 loss = validator.slashedDelegations - amountRecovered;
        $.storedTotal -= loss;
        validator.recoverableAmount = 0;
        $.slashedValidators--;

        emit SlashedValidatorWithdrawn(validator.id, amountRecovered, loss);
    }

    /// @notice Process a withdrawal
    /// @param _requestId The request ID
    /// @param _receiver Address to receive the assets
    /// @param _controller Controller address
    /// @return assets Amount of assets redeemed
    function _processWithdraw(uint256 _requestId, address _receiver, address _controller, bool emergency)
        private
        returns (uint256 assets, uint256 shares)
    {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        _isAuthorizedOperator(_controller);

        RedemptionRequest storage _request = $.pendingRedemptions[_controller][_requestId];

        _NoZeroAddress(_receiver);
        // Ensure the request is claimable
        if (_request.requestTimestamp + withdrawDuration() > block.timestamp) revert NotClaimableYet();

        // Withdraw assets from the SFC
        uint256 amountWithdrawn = _withdrawFromSFC(_requestId, _controller);

        if (amountWithdrawn < _request.assets && !emergency && !_request.emergency) revert WithdrawError();

        shares = _request.shares;

        // Delete the request to not allow double withdrawal
        delete $.pendingRedemptions[_controller][_requestId];
        _removeRequest(_controller, _requestId);

        _withdraw(msg.sender, _receiver, _controller, amountWithdrawn, shares);

        return (amountWithdrawn, shares);
    }

    /// @notice Remove a request from the pending requests
    /// @param _controller Controller address
    /// @param _requestId Request ID
    function _removeRequest(address _controller, uint256 _requestId) private {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        // Get the pending requests array for the controller
        uint256[] storage pendingRequests = $.pendingRequests[_controller];

        // If the array is empty, nothing to do
        if (pendingRequests.length == 0) return;

        // Find the index of the request ID
        for (uint256 i; i < pendingRequests.length; ++i) {
            if (pendingRequests[i] == _requestId) {
                // move the last element to the position of the removed element and pop
                pendingRequests[i] = pendingRequests[pendingRequests.length - 1];
                pendingRequests.pop();
                return;
            }
        }
    }

    /// @notice Withdraw assets from the SFC
    /// @param _requestId Request ID of the withdrawal
    /// @param _controller Controller address
    /// @return amountWithdrawn Amount of assets withdrawn
    function _withdrawFromSFC(uint256 _requestId, address _controller) private returns (uint256 amountWithdrawn) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        RedemptionRequest storage request = $.pendingRedemptions[_controller][_requestId];

        // We fetch the before and after balance in case of slashing and we end up with less assets than desired
        uint256 before = address(this).balance;

        // Withdraw assets from the validators
        for (uint256 j; j < request.withdrawalIds.length; ++j) {
            uint256 validatorId = request.validatorIds[j];
            uint256 requestId = request.withdrawalIds[j];

            if (isSlashed(validatorId)) {
                // If the validator is slashed, we need to make sure we get the refund if more than 0
                uint256 refundAmount = slashingRefundRatio(validatorId);
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
    /// @param _caller Caller address
    /// @param _receiver Receiver address
    /// @param _controller Controller address
    /// @param _assets Amount of assets to withdraw
    /// @param _shares Amount of shares to withdraw
    function _withdraw(address _caller, address _receiver, address _controller, uint256 _assets, uint256 _shares)
        internal
        virtual
        override
    {
        // Deposit raw S into the wrapper
        IWrappedNative(asset()).deposit{value: _assets}();

        // Transfer the assets to the receiver
        IERC20(asset()).safeTransfer(_receiver, _assets);

        emit Withdraw(_caller, _receiver, _controller, _assets, _shares);
    }

    /// @notice Check if a validator is ok
    /// @param _validatorId ID of the validator
    /// @return isOk True if the validator is ok
    function _validatorStatus(uint256 _validatorId) private view returns (bool, uint256) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        (uint256 status, uint256 receivedStake,,,,,) = ISFC($.stakingContract).getValidator(_validatorId);
        return (status == 0, receivedStake);
    }

    /// @notice Get the pending redeem request
    /// @param _requestId ID of the redeem request
    /// @param _controller Controller address
    /// @return shares Amount of shares
    function pendingRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 shares) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        RedemptionRequest storage request = $.pendingRedemptions[_controller][_requestId];

        // Return the shares if the request is pending
        if (request.requestTimestamp + withdrawDuration() > block.timestamp) return request.shares;
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
        if (request.requestTimestamp + withdrawDuration() <= block.timestamp) return request.shares;
        return 0;
    }

    /// @notice Get the pending redeem requests for a user
    /// @param _controller Controller address
    /// @return requests Array of pending requests
    function userPendingRedeemRequests(address _controller)
        external
        view
        returns (RedemptionRequest[] memory requests)
    {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        requests = new RedemptionRequest[]($.pendingRequests[_controller].length);

        for (uint256 i; i < $.pendingRequests[_controller].length; ++i) {
            requests[i] = $.pendingRedemptions[_controller][$.pendingRequests[_controller][i]];
        }
    }

    /// @dev Find the largest validator to deposit
    /// @return largestCapacity of the validator capacity
    function _findLargestValidatorToDeposit() private view returns (uint256 largestCapacity) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        largestCapacity = 0;

        // Get max delegated ratio from the constants manager via the SFC
        uint256 _maxDelegatedRatio = maxDelegatedRatio();

        for (uint256 i; i < $.validators.length; ++i) {
            uint256 capacity = _delegatedCapacity($.validators[i].id, _maxDelegatedRatio);

            if (capacity > largestCapacity) {
                largestCapacity = capacity;
            }
        }
    }

    function _delegatedCapacity(uint256 _validatorId, uint256 _maxDelegatedRatio) private view returns (uint256) {
        uint256 _selfStake = selfStake(_validatorId);
        (, uint256 receivedStake) = _validatorStatus(_validatorId);

        // Avoid division by 0
        if (_selfStake == 0) return 0;

        // Validator delegated capacity is maxDelegatedRatio times the self-stake
        uint256 delegatedCapacity = _selfStake * _maxDelegatedRatio / 1e18;

        // Validator received stake is the amount of S received by the validator
        uint256 capacity = delegatedCapacity - receivedStake;
        return capacity;
    }

    /// @notice Notify the yield to start vesting
    function harvest() external whenNotPaused {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        // We just revert if the last harvest was within the lock duration to prevent ddos 
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
        // You can technically donate by calling withdrawTo with to being this address on wS
        uint256 contractBalance = address(this).balance - $.undelegatedHarvest;

        // Update stored total and total locked
        $.totalLocked = lockedProfit() + contractBalance;
        $.storedTotal += contractBalance;
        $.lastHarvest = block.timestamp;

        // Get validator to deposit
        uint256 validatorId = _getValidatorToDeposit(contractBalance + $.undelegatedHarvest);
        if (validatorId == type(uint256).max) $.undelegatedHarvest += contractBalance;
        else {
            // Get validator from storage
            Validator storage validator = $.validators[validatorId];

            // Update delegations
            validator.delegations += contractBalance + $.undelegatedHarvest;

            // Delegate assets to the validator only if a single validator can handle the deposit amount
            ISFC($.stakingContract).delegate{value: contractBalance + $.undelegatedHarvest}(validator.id);
            $.undelegatedHarvest = 0;
        }

        emit Notify(msg.sender, contractBalance);
    }

    /// @notice Claim pending rewards from validators
    function _claim() private {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        for (uint256 i; i < $.validators.length; ++i) {
            Validator storage validator = $.validators[i];
            if (validator.claim) {
                // Claim rewards from the staking contract
                uint256 pending = ISFC($.stakingContract).pendingRewards(address(this), validator.id);
                if (pending > 0) ISFC($.stakingContract).claimRewards(validator.id);

                // We claimed remaining rewards for inactive validator and now set shouldClaim to false
                (bool isOk,) = _validatorStatus(validator.id);
                if (!isOk) _setValidatorStatus(i, false, false);
            }
        }
    }

    /// @notice Charge fees
    /// @param _amount Amount of assets to charge
    function _chargeFees(uint256 _amount) private {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        // Get fees .total will never be 0
        uint256 beefyFeeAmount = _amount * IFeeConfig($.beefyFeeConfig).getFees(address(this)).total / 1e18;
        uint256 liquidityFeeAmount = 0;
        if ($.liquidityFee > 0) liquidityFeeAmount = _amount * $.liquidityFee / 1e18;

        uint256 total = beefyFeeAmount + liquidityFeeAmount;
        if (total > 0) {
            IWrappedNative(asset()).deposit{value: total}();
            if (beefyFeeAmount > 0) IERC20(asset()).safeTransfer($.beefyFeeRecipient, beefyFeeAmount);
            if (liquidityFeeAmount > 0) IERC20(asset()).safeTransfer($.liquidityFeeRecipient, liquidityFeeAmount);
        }

        emit ChargedFees(beefyFeeAmount, liquidityFeeAmount);
    }

    /// @notice Get validator index by validator ID
    /// @param _validatorId Validator ID
    /// @return index Index of the validator
    function _getValidatorIndex(uint256 _validatorId) private view returns (uint256) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        for (uint256 i; i < $.validators.length; ++i) {
            if ($.validators[i].id == _validatorId) return i;
        }
        revert ValidatorNotFound();
    }

    /// @notice Check if an operator is authorized to withdraw
    /// @param _controller Controller address
    /// @param _operator Operator address
    /// @return isOperator True if the operator is authorized
    function isOperator(address _controller, address _operator) external view returns (bool) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        return $.isOperator[_controller][_operator];
    }

    /// @notice Remaining locked profit after a notification
    /// @return locked Amount remaining to be vested
    function lockedProfit() public view returns (uint256 locked) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        uint256 _lockDuration = $.lockDuration;
        if (_lockDuration == 0) return 0;
        uint256 elapsed = block.timestamp - $.lastHarvest;
        uint256 remaining = elapsed < _lockDuration ? _lockDuration - elapsed : 0;
        locked = $.totalLocked * remaining / _lockDuration;
    }

    /// @notice Get the slashing refund ratio of a validator
    /// @param _validatorId ID of the validator
    /// @return slashingRefundRatio Slashing refund ratio
    function slashingRefundRatio(uint256 _validatorId) private view returns (uint256) {
        return ISFC(getBeefySonicStorage().stakingContract).slashingRefundRatio(_validatorId);
    }

    /// @notice Get the self-stake of a validator
    /// @param _validatorId ID of the validator
    /// @return selfStake Amount of assets staked
    function selfStake(uint256 _validatorId) private view returns (uint256) {
        return ISFC(getBeefySonicStorage().stakingContract).getSelfStake(_validatorId);
    }

    /// @notice Check if a validator is slashed
    /// @param _validatorId ID of the validator
    function isSlashed(uint256 _validatorId) private view returns (bool) {
        return ISFC(getBeefySonicStorage().stakingContract).isSlashed(_validatorId);
    }

    /// @notice Get the maximum delegate ratio
    /// @return maxDelegatedRatio Maximum delegate ratio
    function maxDelegatedRatio() private view returns (uint256) {    
        return IConstantsManager(ISFC(getBeefySonicStorage().stakingContract).constsAddress()).maxDelegatedRatio();
    }

    /// @notice Get the number of validators
    /// @return _length Number of validators
    function validatorsLength() external view returns (uint256) {
        return getBeefySonicStorage().validators.length;
    }

    /// @notice Get the total locked amount
    /// @return totalLocked Total locked amount
    function totalLocked() external view returns (uint256) {
        return getBeefySonicStorage().totalLocked;
    }

    /// @notice Get the last harvest timestamp
    /// @return lastHarvest Last harvest timestamp
    function lastHarvest() external view returns (uint256) {
        return getBeefySonicStorage().lastHarvest;
    }

    /// @notice Get the rate used by Balancer
    /// @return rate Rate
    function getRate() external view returns (uint256) {
        return convertToAssets(1e18);
    }

    /// @notice Get the price per full share used by Beefy
    /// @return pricePerFullShare Price per full share
    function getPricePerFullShare() external view returns (uint256) {
        return convertToAssets(1e18);
    }

    /// @notice Override the decimals function to match underlying decimals
    /// @return _decimals Decimals of the underlying token
    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
        return ERC4626Upgradeable.decimals();
    }

    /// @notice Total assets on this contract
    /// @return total Total amount of assets
    function totalAssets() public view override returns (uint256 total) {
        total = getBeefySonicStorage().storedTotal - lockedProfit();
    }

    /// @notice Get the lock duration
    /// @return lockDuration Lock duration
    function lockDuration() public view returns (uint256) {
        return getBeefySonicStorage().lockDuration;
    }

    /// @notice Get the liquidity fee
    /// @return liquidityFee Liquidity fee
    function liquidityFee() public view returns (uint256) {
        return getBeefySonicStorage().liquidityFee;
    }

    /// @notice Get a validator
    /// @param _validatorIndex Index of the validator
    /// @return validator Validator struct
    function validatorByIndex(uint256 _validatorIndex) external view returns (Validator memory) {
        return getBeefySonicStorage().validators[_validatorIndex];
    }

    /// @notice Preview withdraw always reverts for async flows
    function previewWithdraw(uint256) public pure virtual override returns (uint256) {
        revert ERC7540AsyncFlow();
    }

    /// @notice Preview redeem always reverts for async flows
    function previewRedeem(uint256) public pure virtual override returns (uint256) {
        revert ERC7540AsyncFlow();
    }

    /**
     * @dev See {IERC4626-maxDeposit}.
     */
    function maxDeposit(address) public view virtual override returns (uint256) {
        return _findLargestValidatorToDeposit();
    }

    /**
     * @dev See {IERC4626-maxMint}.
     */
    function maxMint(address) public view virtual override returns (uint256) {
        return convertToShares(_findLargestValidatorToDeposit());
    }

    /// @notice Get the want token
    /// @return want Address of the want token
    function want() external view returns (address) {
        return asset();
    }

    /// @notice Get the Beefy fee recipient
    /// @return beefyFeeRecipient Address of the Beefy fee recipient
    function feeRecipients() external view returns (address beefyFeeRecipient, address liquidityFeeRecipient) {
        return (getBeefySonicStorage().beefyFeeRecipient, getBeefySonicStorage().liquidityFeeRecipient);
    }

    /// @notice Get the Beefy fee configuration
    /// @return beefyFeeConfig Address of the Beefy fee configuration
    function beefyFeeConfig() external view returns (address) {
        return getBeefySonicStorage().beefyFeeConfig;
    }

    /// @notice Get the keeper
    /// @return keeper Address of the keeper
    function keeper() external view returns (address) {
        return getBeefySonicStorage().keeper;
    }

    /// @notice Get the withdraw duration
    /// @return withdrawDuration Withdraw duration
    function withdrawDuration() public view returns (uint256) {
        return IConstantsManager(ISFC(getBeefySonicStorage().stakingContract).constsAddress()).withdrawalPeriodTime();
    }

    /// @notice Add a new validator
    /// @param _validatorId ID of the validator
    function addValidator(uint256 _validatorId) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        // Check if validator already exists
        for (uint256 i; i < $.validators.length; ++i) {
            if ($.validators[i].id == _validatorId) revert InvalidValidatorIndex();
        }

        (bool isOk,) = _validatorStatus(_validatorId);
        if (!isOk) revert NotOK();
        // Create new validator
        Validator memory validator = Validator({
            id: _validatorId,
            delegations: 0,
            slashedWId: 0,
            recoverableAmount: 0,
            slashedDelegations: 0,
            active: true,
            claim: true
        });

        // Add to validators array
        uint256 validatorIndex = $.validators.length;
        $.validators.push(validator);

        emit ValidatorAdded(_validatorId, validatorIndex);
    }

    /// @notice Set a validator's active status
    /// @param _validatorIndex Index of the validator
    /// @param _active Whether the validator is active
    /// @param _shouldClaim Whether the validator should claim
    function setValidatorStatus(uint256 _validatorIndex, bool _active, bool _shouldClaim) external onlyOwner {
        _setValidatorStatus(_validatorIndex, _active, _shouldClaim);
    }

    /// @notice Set a validator's active status
    /// @param _validatorIndex Index of the validator
    /// @param _active Whether the validator is active
    /// @param _shouldClaim Whether the validator should claim
    function _setValidatorStatus(uint256 _validatorIndex, bool _active, bool _shouldClaim) private {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        if (_validatorIndex >= $.validators.length) revert InvalidValidatorIndex();

        $.validators[_validatorIndex].active = _active;
        $.validators[_validatorIndex].claim = _shouldClaim;

        emit ValidatorStatusChanged(_validatorIndex, _active, _shouldClaim);
    }

    /// @notice Set an operator to finalize the claim of the request to withdraw
    /// @param _operator Address of the operator
    /// @param _approved Whether the operator is approved
    function setOperator(address _operator, bool _approved) external returns (bool) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        $.isOperator[msg.sender][_operator] = _approved;
        emit OperatorSet(msg.sender, _operator, _approved);
        return true;
    }

    /// @notice Set the Beefy fee recipient
    /// @param _beefyFeeRecipient Address of the new Beefy fee recipient
    function setBeefyFeeRecipient(address _beefyFeeRecipient) external onlyOwner {
        _NoZeroAddress(_beefyFeeRecipient);
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit BeefyFeeRecipientSet($.beefyFeeRecipient, _beefyFeeRecipient);
        $.beefyFeeRecipient = _beefyFeeRecipient;
    }

    /// @notice Set the Beefy fee configuration
    /// @param _beefyFeeConfig Address of the new Beefy fee configuration
    function setBeefyFeeConfig(address _beefyFeeConfig) external onlyOwner {
        _NoZeroAddress(_beefyFeeConfig);
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit BeefyFeeConfigSet($.beefyFeeConfig, _beefyFeeConfig);
        $.beefyFeeConfig = _beefyFeeConfig;
    }

    /// @notice Set the liquidity fee recipient
    /// @param _liquidityFeeRecipient Address of the new liquidity fee recipient
    function setLiquidityFeeRecipient(address _liquidityFeeRecipient) external onlyOwner {
        _NoZeroAddress(_liquidityFeeRecipient);
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
        _NoZeroAddress(_keeper);
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit KeeperSet($.keeper, _keeper);
        $.keeper = _keeper;
    }

    /// @notice Set the lock duration
    /// @param _lockDuration Duration of the lock
    function setLockDuration(uint32 _lockDuration) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit LockDurationSet($.lockDuration, _lockDuration);
        $.lockDuration = _lockDuration;
    }

    function setMinHarvest(uint256 _minHarvest) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit MinHarvestSet($.minHarvest, _minHarvest);
        $.minHarvest = _minHarvest;
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

    /// @notice Check if an address is not zero
    /// @param _address Address to check
    function _NoZeroAddress(address _address) private pure returns (address) {
        if (_address == address(0)) revert ZeroAddress();
        return _address;
    }

    /// @notice EIP 7575: Get the share token address
    /// @return shareTokenAddress Address of the share token which is this address.
    function share() external view returns (address shareTokenAddress) {
        return address(this);
    }

    /// @notice Checks if a contract implements an interface.
    /// @param interfaceId The interface identifier, as specified in ERC-165.
    /// @return supported True if the contract implements `interfaceId` and
    function supportsInterface(bytes4 interfaceId) external pure returns (bool supported) {
        if (
            interfaceId == 0xe3bc4e65 || interfaceId == 0x620ee8e4 || interfaceId == 0x2f0a18c5
                || interfaceId == 0x01ffc9a7 || interfaceId == 0x36372b07
        ) return true;
        return false;
    }

    /// @notice Receive function for receiving Native Sonic
    /// @dev we dont allow receiving Native Sonic unless from wrapper or SFC
    receive() external payable {
        if (msg.sender != address(asset()) && msg.sender != address(getBeefySonicStorage().stakingContract)) {
            revert NotAuthorized();
        }
    }
}
