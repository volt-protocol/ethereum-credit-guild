// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {GatewayV1} from "./GatewayV1.sol";

/// @title ECG Gateway V1 - NO ACL version
/// @notice Gateway to interract via multicall with the ECG
/// @dev this contract does not check if calls are allowed
/// use at your own risk
contract GatewayV1NoACL is GatewayV1 {
    /// @notice Executes an external call to a specified target. All calls are allowed
    /// @dev anyone can use the gateway so if any funds are left in it, anyone can take them
    /// @param target The address of the contract to call.
    /// @param data The calldata to send.
    function callExternal(
        address target,
        bytes calldata data
    ) public override afterEntry {
        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            _getRevertMsg(result);
        }
    }

    function allowCall(
        address /*target*/,
        bytes4 /*functionSelector*/,
        bool /*allowed*/
    ) public override view onlyOwner {
        revert("GatewayV1NoACL: unused function");
    }
}
