// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IBeefySonic } from "./interfaces/IBeefySonic.sol";

/// @title BeefySonic Storage Utils
/// @author weso, Beefy
/// @notice Storage utilities for BeefySonic control
contract BeefySonicStorageUtils {
    /// @dev keccak256(abi.encode(uint256(keccak256("beefy.storage.BeefySonic")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BeefySonicStorageLocation = 0xe129f5f787afe84f43d994d232cb3da30ecdd4d65ff3407926c4706d66dc7e00;

    /// @dev Get BeefySonic storage
    /// @return $ Storage pointer
    function getBeefySonicStorage() internal pure returns (IBeefySonic.BeefySonicStorage storage $) {
        assembly {
            $.slot := BeefySonicStorageLocation
        }
    }
}