// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IBeefyGemsFactory} from "../interfaces/IBeefyGemsFactory.sol";

/// @title Beefy Gems
/// @author Beefy, weso
/// @dev Beefy Gems Season Program
contract BeefyGems is ERC20Upgradeable, OwnableUpgradeable {

    address private factory;
    uint256 private _seasonNum;

    /// @notice Initialize the contract
    /// @param _name Name of the token
    /// @param _symbol Symbol of the token
    /// @param _treasury Address of the treasury
    /// @param _amount Amount of gems to mint
    /// @param _season Season number
    function initialize(
        string memory _name, 
        string memory _symbol, 
        address _treasury, 
        uint256 _amount,
        uint256 _season
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __Ownable_init(msg.sender);
        factory = msg.sender;
        _seasonNum = _season;
        _mint(_treasury, _amount);
    }

    /// @notice Redeem gems for S
    /// @param _amount Amount of gems to redeem
    function redeem(uint256 _amount) external {
        IBeefyGemsFactory(factory).redeem(_seasonNum, _amount, msg.sender);
    }

    /// @notice Burn gems
    /// @param _amount Amount of gems to burn
    /// @param _who Address of the account to burn gems from
    function burn(uint256 _amount, address _who) external onlyOwner {
        _burn(_who, _amount);
    }

    /// @notice Get the price for a full share
    /// @return Price for a full share
    function getPriceForFullShare() external view returns (uint256) {
        return IBeefyGemsFactory(factory).getPriceForFullShare(_seasonNum);
    }

    function season() external view returns (uint256) {
        return _seasonNum;
    }
}