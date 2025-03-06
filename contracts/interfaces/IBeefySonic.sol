// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;


interface IBeefySonic {
   struct BeefySonicStorage {
        uint256 storedTotal;
        uint256 totalLocked;
        uint256 lastNotify;
        uint256 lockDuration;
   }
}