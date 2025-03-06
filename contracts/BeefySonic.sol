// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Upgradeable, ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IBeefySonic} from "./interfaces/IBeefySonic.sol";
import {BeefySonicStorageUtils} from "../contracts/BeefySonicStorageUtils.sol";

/// @title BeefySonic
/// @author Beefy, weso
/// @dev Interest bearing staked version of the Sonic token
contract BeefySonic is IBeefySonic, UUPSUpgradeable, ERC20Upgradeable, ERC4626Upgradeable, OwnableUpgradeable, BeefySonicStorageUtils {
    using SafeERC20 for IERC20;

    event Notify(address notifier, uint256 amount);

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }  

    /// @param underlying Address of the underlying token
    /// @param name Name of the staked token
    /// @param symbol Symbol of the staked token
    function initialize(
        IERC20 underlying, 
        string memory name,
        string memory symbol
    ) public initializer {
        __UUPSUpgradeable_init();
        __ERC20_init(name, symbol);
        __ERC4626_init(underlying);
        __Ownable_init(msg.sender);
    }

    /// @notice Override the decimals function to match underlying decimals
    /// @return _decimals Decimals of the staked cap token
    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
        return ERC4626Upgradeable.decimals();
    }

    /// @notice Notify the yield to start vesting
    function notify() external {
        uint256 total = address(this).balance;
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if (total > $.storedTotal) {
            uint256 diff = total - $.storedTotal;
            $.totalLocked = lockedProfit() + diff;
            $.storedTotal = total;
            $.lastNotify = block.timestamp;

            emit Notify(msg.sender, diff);
        }
    }

    /// @notice Remaining locked profit after a notification
    /// @return locked Amount remaining to be vested
    function lockedProfit() public view returns (uint256 locked) {
        BeefySonicStorage storage $ = getBeefySonicStorage();
        if ($.lockDuration == 0) return 0;
        uint256 elapsed = block.timestamp - $.lastNotify;
        uint256 remaining = elapsed < $.lockDuration ? $.lockDuration - elapsed : 0;
        locked = $.totalLocked * remaining / $.lockDuration;
    }

    /// @notice Total vested cap tokens on this contract
    /// @return total Total amount of vested cap tokens
    function totalAssets() public view override returns (uint256 total) {
        total = getBeefySonicStorage().storedTotal - lockedProfit();
    }

    /// @notice Function to authorize upgrades, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Receive function for receiving Native Sonic
    receive() external payable {}
}
