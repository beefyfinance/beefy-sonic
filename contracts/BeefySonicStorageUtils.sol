// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IBeefySonic } from "./interfaces/IBeefySonic.sol";

/// @title BeefySonic Storage Utils
/// @author weso, Beefy
/// @notice Storage utilities for BeefySonic control
contract BeefySonicStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("beefy.storage.BeefySonic")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BeefySonicStorageLocation = 0x62b58b20e3c9a6ebfe98e7c036f01117f270db086cfa27fbd53ec62e54038731;

    /// @dev Get BeefySonic storage
    /// @return $ Storage pointer
    function getBeefySonicStorage() internal pure returns (IBeefySonic.BeefySonicStorage storage $) {
        assembly {
            $.slot := BeefySonicStorageLocation
        }
    }
}