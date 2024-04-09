// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {GatewayV1} from "./GatewayV1.sol";

import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";


/// @title ECG Gateway V1 - Bidder version
/// @notice Gateway to interract via multicall with the ECG
/// Owner can select which user are allowed to use it
contract GatewayV1_Bidder is GatewayV1 {

    mapping(address=>bool) public allowedUsers;

    /// @notice Executes an external call to a specified target.
    ///         Only allows allowed address to use it
    /// @param target The address of the contract to call.
    /// @param data The calldata to send.
    function callExternal(
        address target,
        bytes calldata data
    ) public override afterEntry {
        require(allowedUsers[_originalSender], "GatewayV1_bidder: user not allowed");

        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            _getRevertMsg(result);
        }
    }

    /// @notice set/unset a user to the allowlist
    /// @param user the user to allow/disallow. all users are disallowed by default
    /// @param isAllowed whether the user is allowed or not
    function setAllowedUser(address user, bool isAllowed) public onlyOwner() {
        allowedUsers[user] = isAllowed;
    }
}
