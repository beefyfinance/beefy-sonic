// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title Beefy Gems
/// @author Beefy, weso
/// @dev Beefy Gems Season Program
contract BeefyGems is ERC20Upgradeable, OwnableUpgradeable {

    /// @notice Initialize the contract
    /// @param _name Name of the token
    /// @param _symbol Symbol of the token
    /// @param _treasury Address of the treasury
    /// @param _amount Amount of gems to mint
    function initialize(
        string memory _name, 
        string memory _symbol, 
        address _treasury, 
        uint256 _amount
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __Ownable_init(msg.sender);

        _mint(_treasury, _amount);
    }

    /// @notice Burn gems
    /// @param _amount Amount of gems to burn
    /// @param _who Address of the account to burn gems from
    function burn(uint256 _amount, address _who) public onlyOwner {
        _burn(_who, _amount);
    }
}