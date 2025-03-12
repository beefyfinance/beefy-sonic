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
import {IFeeConfig} from "./interfaces/IFeeConfig.sol";
import {BeefySonicStorageUtils} from "../contracts/BeefySonicStorageUtils.sol";

/// @title BeefySonic
/// @author Beefy, weso
/// @dev Interest bearing staked version of the Sonic token
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
    /// @param _beefyFeeConfig Address of the Beefy fee configuration
    /// @param _liquidityFeeRecipient Address of the liquidity fee recipient
    /// @param _liquidityFee Liquidity fee percentage
    /// @param _name Name of the staked token
    /// @param _symbol Symbol of the staked token
    function initialize(
        address _want, 
        address _stakingContract,
        address _beefyFeeRecipient,
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

        if (_liquidityFee > 0.1e18) revert InvalidLiquidityFee();

        BeefySonicStorage storage $ = getBeefySonicStorage();
        $.want = _want;
        $.stakingContract = _stakingContract;
        $.beefyFeeRecipient = _beefyFeeRecipient;
        $.beefyFeeConfig = _beefyFeeConfig;
        $.liquidityFeeRecipient = _liquidityFeeRecipient;
        $.liquidityFee = _liquidityFee;
        $.lockDuration = 1 days;
        $.withdrawDuration = 14 days;
    }

    /// @notice Deposit assets into the vault
    /// @param caller Address of the caller
    /// @param receiver Address of the receiver
    /// @param assets Amount of assets to deposit
    /// @param shares Amount of shares to mint
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override whenNotPaused {
        BeefySonicStorage storage $ = getBeefySonicStorage(); 

        if (assets == 0 || shares == 0) revert ZeroDeposit();  

        // Withdraw assets from the wrapped native token
        IWrappedNative($.want).withdraw(assets);

        // Get the validator to deposit to
        uint256 validatorId = _getValidatorToDeposit(assets);
        
        // Delegate assets to the validator only if a single validator can handle the deposit amount
        ISFC($.stakingContract).delegate{value: assets}(validatorId);
        $.validators[validatorId].delegations += assets;
        $.storedTotal += assets;

        super._deposit(caller, receiver, assets, shares);
        emit Deposit(totalAssets(), assets);
    }

    /// @notice Get the validator to deposit to
    /// @param _amount Amount of assets to deposit
    /// @return validatorId ID of the validator
    function _getValidatorToDeposit(uint256 _amount) internal view returns (uint256 validatorId) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        
        // Ensure we have validators
        if($.validators.length == 0) revert NoValidators();

        // Loop and try to deposit into the first validator in the set with capacity
        for(uint256 i = 0; i < $.validators.length; i++) {
            Validator memory validator = $.validators[i];
            if(validator.active) {
                uint256 selfStake = ISFC($.stakingContract).getSelfStake(validator.id);
                (, uint256 receivedStake,,,,,) = ISFC($.stakingContract).getValidator(validator.id);
                
                /// Validator delegated capacity is 15x the self-stake
                uint256 delegatedCapacity = selfStake * 15;
                
                // Check if the validator has available capacity
                if (delegatedCapacity > receivedStake) {
                   uint256 availableCapacity = delegatedCapacity - receivedStake;
                   if (availableCapacity >= _amount) return validator.id;
                }
            }
        }

        revert NoValidatorsWithCapacity();
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        (uint256[] memory validatorIds, uint256[] memory amounts) = _getValidatorsToWithdraw(assets);

        uint256[] memory requestIds = new uint256[](validatorIds.length);

        for (uint256 i = 0; i < validatorIds.length; i++) {
            uint256 requestId = _withdrawId();
            requestIds[i] = requestId;
            ISFC($.stakingContract).undelegate(validatorIds[i], requestId, amounts[i]);
            $.validators[validatorIds[i]].delegations -= amounts[i];
            $.storedTotal -= amounts[i];
        }

        WithdrawRequest memory request = WithdrawRequest({
            shares: shares,
            assets: assets,
            requestTime: block.timestamp,
            receiver: receiver,
            processed: false,
            requestIds: requestIds,
            validatorIds: validatorIds,
            withdrawAmounts: amounts
        });

        $.withdrawRequests[owner].push(request);

        emit WithdrawQueued(owner, receiver, shares, assets, validatorIds, amounts);
    }

    /// @notice Process a queued withdrawal
    /// @return amountWithdrawn The amount of assets withdrawn
    function processWithdraw() external returns (uint256 amountWithdrawn) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if ($.withdrawRequests[msg.sender].length == 0) revert NothingToWithdraw();

        for (uint256 i; i < $.withdrawRequests[msg.sender].length; i++) {
            amountWithdrawn += processWithdraw(i);
        }
    }

    function processWithdraw(uint256 index) public returns (uint256 amountWithdrawn) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        WithdrawRequest storage request = $.withdrawRequests[msg.sender][index];
        
        if (request.processed) revert NothingToWithdraw();
        
        uint256 before = address(this).balance;
        for (uint256 j; j < request.requestIds.length; j++) {
            uint256 validatorId = request.validatorIds[j];
            uint256 requestId = request.requestIds[j];
            bool isSlashed = ISFC($.stakingContract).isSlashed(validatorId);
            if (isSlashed) {
                uint256 refundAmount = ISFC($.stakingContract).slashingRefundRatio(validatorId);
                if (refundAmount > 0) {
                    ISFC($.stakingContract).withdraw(validatorId, requestId);
                }
            } else {
                ISFC($.stakingContract).withdraw(validatorId, requestId);
            }
        }
        
        amountWithdrawn += address(this).balance - before;
        request.processed = true;
        $.totalQueuedWithdrawals -= request.assets;
        IWrappedNative($.want).deposit{value: amountWithdrawn}();
        IERC20($.want).safeTransfer(request.receiver, amountWithdrawn);
        
        emit WithdrawProcessed(msg.sender, request.receiver, request.shares, amountWithdrawn);
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

    function _withdrawId() internal returns (uint256) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        return $.withdrawRequestId++;
    }
   
    /// @notice Notify the yield to start vesting
    function harvest() external whenNotPaused {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if (block.timestamp - $.lastHarvest <= $.lockDuration) return;

        uint256 beforeBal = address(this).balance;
        _claim();
        uint256 claimed = address(this).balance - beforeBal;
        _chargeFees(claimed);

        uint256 total = totalAssets() + address(this).balance;

        if (total > $.storedTotal) {
            uint256 diff = total - $.storedTotal;
            $.totalLocked = lockedProfit() + diff;
            $.storedTotal = total;
            $.lastHarvest = block.timestamp;

            _getValidatorToDeposit(diff);

            emit Notify(msg.sender, diff);
        }
    }

    /// @notice Claim pending rewards from validators
    function _claim() internal {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        for (uint256 i = 0; i < $.validators.length; i++) {
            Validator storage validator = $.validators[i];
            if (validator.active) {
                ISFC($.stakingContract).claimRewards(validator.id);
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
        total = getBeefySonicStorage().storedTotal - lockedProfit() - getBeefySonicStorage().totalQueuedWithdrawals;
    }

    function _getValidatorsToWithdraw(uint256 assets) internal returns (uint256[] memory _validatorIds, uint256[] memory _withdrawAmounts) {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        uint256 remaining = assets;

        // loop backwards in the validators array withdraw from newest validator first
        for (uint256 i = $.validators.length - 1; i >= 0; i--) {
            Validator storage validator = $.validators[i];
            if (validator.delegations >= assets) {
                remaining -= assets;
                $.validatorIds.push(validator.id);
                $.withdrawAmounts.push(assets);
                break;
            } else if (validator.delegations > 0) {
                remaining -= validator.delegations;
                $.validatorIds.push(validator.id);
                $.withdrawAmounts.push(validator.delegations);
            }
        }

        _validatorIds = $.validatorIds;
        _withdrawAmounts = $.withdrawAmounts;
        delete $.validatorIds;
        delete $.withdrawAmounts;
    }

    /// @notice Get pending withdrawal requests for an address
    /// @param owner Address to check
    /// @return length Number of pending withdrawal requests
    function getPendingWithdrawalsLength(address owner) external view returns (uint256) {
        BeefySonicStorage storage $ = getBeefySonicStorage();

        return $.withdrawRequests[owner].length;
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
            active: true
        });
        
        // Add to validators array
        uint256 validatorIndex = $.validators.length;
        $.validators.push(validator);
        
        emit ValidatorAdded(validatorId, validatorIndex);
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

    /// @notice Set the Beefy fee recipient
    /// @param _beefyFeeRecipient Address of the new Beefy fee recipient
    function setBeefyFeeRecipient(address _beefyFeeRecipient) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit SetBeefyFeeRecipient($.beefyFeeRecipient, _beefyFeeRecipient);
        $.beefyFeeRecipient = _beefyFeeRecipient;
    }

    /// @notice Set the Beefy fee configuration
    /// @param _beefyFeeConfig Address of the new Beefy fee configuration
    function setBeefyFeeConfig(address _beefyFeeConfig) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit SetBeefyFeeConfig($.beefyFeeConfig, _beefyFeeConfig);
        $.beefyFeeConfig = _beefyFeeConfig;
    }

    /// @notice Set the liquidity fee recipient
    /// @param _liquidityFeeRecipient Address of the new liquidity fee recipient    
    function setLiquidityFeeRecipient(address _liquidityFeeRecipient) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit SetLiquidityFeeRecipient($.liquidityFeeRecipient, _liquidityFeeRecipient);
        $.liquidityFeeRecipient = _liquidityFeeRecipient;
    }

    /// @notice Set the liquidity fee percentage
    /// @param _liquidityFee Percentage of the fee
    function setLiquidityFee(uint256 _liquidityFee) external onlyOwner {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        emit SetLiquidityFee($.liquidityFee, _liquidityFee);
        if (_liquidityFee > 0.1e18) revert InvalidLiquidityFee();
        $.liquidityFee = _liquidityFee;
    }

    /// @notice Function to authorize upgrades, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Receive function for receiving Native Sonic
    receive() external payable {}
}
