// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title LowLevelCall
/// @notice Util for low-level calls that forward the revert message
/// @author eswak
abstract contract LowLevelCall {
    function _call(address target, bytes memory data) internal {
        (bool success, ) = address(target).call(data);
        if (!success) {
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }
}
