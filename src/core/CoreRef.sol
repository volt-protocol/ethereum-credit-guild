// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/// @title A Reference to Core
/// @author eswak
/// @notice defines some modifiers and utilities around interacting with Core
abstract contract CoreRef is Pausable {
    /// @notice emitted when the reference to core is updated
    event CoreUpdate(address indexed oldCore, address indexed newCore);

    /// @notice reference to Core
    Core private _core;

    constructor(address coreAddress) {
        _core = Core(coreAddress);
    }

    /// @notice named onlyCoreRole to prevent collision with OZ onlyRole modifier
    modifier onlyCoreRole(bytes32 role) {
        require(_core.hasRole(role, msg.sender), "UNAUTHORIZED");
        _;
    }

    /// @notice address of the Core contract referenced
    function core() public view returns (Core) {
        return _core;
    }

    /// @notice WARNING CALLING THIS FUNCTION CAN POTENTIALLY
    /// BRICK A CONTRACT IF CORE IS SET INCORRECTLY
    /// @notice set new reference to core
    /// only callable by governor
    /// @param newCore to reference
    function setCore(
        address newCore
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _setCore(newCore);
    }

    /// @notice WARNING CALLING THIS FUNCTION CAN POTENTIALLY
    /// BRICK A CONTRACT IF CORE IS SET INCORRECTLY
    /// @notice set new reference to core
    /// @param newCore to reference
    function _setCore(address newCore) internal {
        address oldCore = address(_core);
        _core = Core(newCore);

        emit CoreUpdate(oldCore, newCore);
    }

    /// @notice set pausable methods to paused
    function pause() public onlyCoreRole(CoreRoles.GUARDIAN) {
        _pause();
    }

    /// @notice set pausable methods to unpaused
    function unpause() public onlyCoreRole(CoreRoles.GUARDIAN) {
        _unpause();
    }

    /// ------------------------------------------
    /// ------------ Emergency Action ------------
    /// ------------------------------------------

    /// inspired by MakerDAO Multicall:
    /// https://github.com/makerdao/multicall/blob/master/src/Multicall.sol

    /// @notice struct to pack calldata and targets for an emergency action
    struct Call {
        /// @notice target address to call
        address target;
        /// @notice amount of eth to send with the call
        uint256 value;
        /// @notice payload to send to target
        bytes callData;
    }

    /// @notice due to inflexibility of current smart contracts,
    /// add this ability to be able to execute arbitrary calldata
    /// against arbitrary addresses.
    /// callable only by governor
    function emergencyAction(
        Call[] calldata calls
    )
        external
        payable
        onlyCoreRole(CoreRoles.GOVERNOR)
        returns (bytes[] memory returnData)
    {
        returnData = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            address payable target = payable(calls[i].target);
            uint256 value = calls[i].value;
            bytes calldata callData = calls[i].callData;

            (bool success, bytes memory returned) = target.call{value: value}(
                callData
            );
            require(success, "CoreRef: underlying call reverted");
            returnData[i] = returned;
        }
    }
}
