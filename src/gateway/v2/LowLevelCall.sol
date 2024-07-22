// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

abstract contract LowLevelCall {
    /// @notice Emitted when a call fails with an error.
    error LowLevelCallError(bytes innerError);

    function _call(address target, bytes memory data) internal {
        (bool success, bytes memory result) = address(target).call(data);
        if (!success) {
            _getRevertMsg(result);
        }
    }

    /// @dev Extracts a revert message from failed call return data.
    /// @param _returnData The return data from the failed call.
    function _getRevertMsg(bytes memory _returnData) internal pure {
        // If the _res length is less than 68, then
        // the transaction failed with custom error or silently (without a revert message)
        if (_returnData.length < 68) {
            revert LowLevelCallError(_returnData);
        }

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        revert(abi.decode(_returnData, (string))); // All that remains is the revert string
    }
}
