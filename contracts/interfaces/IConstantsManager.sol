// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;


interface IConstantsManager {
    function maxDelegatedRatio() external view returns (uint256);
    function withdrawalPeriodTime() external view returns (uint256);
}