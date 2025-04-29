// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBeefyGemsFactory {
    function getPriceForFullShare(uint256 _season) external view returns (uint256);
    function redeem(uint256 _season, uint256 _amount, address _who) external;
}