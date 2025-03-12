// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint wad) external;
}