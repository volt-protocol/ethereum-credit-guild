// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title An override of the regular OZ governance/TimelockController to allow uniform
/// access control in the ECG system based on roles defined in Core.
/// @dev The roles and roles management from OZ access/AccessControl.sol are ignored, we
/// chose not to fork TimelockController and just bypass its access control system, to
/// introduce as few code changes as possible on top of OpenZeppelin's governance code.
/// @author eswak
contract GuildTimelockController is TimelockController, CoreRef {
    constructor(
        address _core,
        uint256 _minDelay
    )
        CoreRef(_core)
        TimelockController(
            _minDelay,
            new address[](0),
            new address[](0),
            address(0)
        )
    {}

    /// @dev override of OZ access/AccessControl.sol inherited by governance/TimelockController.sol
    /// This will check roles with Core, and not with the storage mapping from AccessControl.sol
    function hasRole(
        bytes32 role,
        address account
    ) public view virtual override returns (bool) {
        return core().hasRole(role, account);
    }

    /// @dev override of OZ access/AccessControl.sol, noop because role management is handled in Core.
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal override {}

    /// @dev override of OZ access/AccessControl.sol, noop because role management is handled in Core.
    function _grantRole(bytes32 role, address account) internal override {}

    /// @dev override of OZ access/AccessControl.sol, noop because role management is handled in Core.
    function _revokeRole(bytes32 role, address account) internal override {}
}
