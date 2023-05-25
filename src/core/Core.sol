// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {CoreRoles} from "@src/core/CoreRoles.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

/// @title Core access control of the Ethereum Credit Guild
/// @author Volt Protocol
/// @notice maintains roles and access control
contract Core is AccessControlEnumerable {
    /// @notice construct Core
    constructor() {
        // For initial setup before going live, deployer can then call
        // renounceRole(bytes32 role, address account)
        _setupRole(CoreRoles.GOVERNOR, msg.sender);

        // Core itself is governor so guardian can have indirect access to revoke other roles
        _setupRole(CoreRoles.GOVERNOR, address(this));

        // Initial roles setup: direct hierarchy, everything under governor
        _setRoleAdmin(CoreRoles.GOVERNOR, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.GUARDIAN, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.CREDIT_MINTER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.RATE_LIMITED_CREDIT_MINTER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.GUILD_MINTER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.GAUGE_ADD, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.GAUGE_REMOVE, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.GAUGE_PARAMETERS, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.GAUGE_PNL_NOTIFIER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.TERM_OFFBOARD, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.TERM_HARDCAP, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.TIMELOCK_PROPOSER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.TIMELOCK_EXECUTOR, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.TIMELOCK_CANCELLER, CoreRoles.GOVERNOR);
    }

    /// @notice creates a new role to be maintained
    /// @param role the new role id
    /// @param adminRole the admin role id for `role`
    /// @dev can also be used to update admin of existing role
    function createRole(
        bytes32 role,
        bytes32 adminRole
    ) external onlyRole(CoreRoles.GOVERNOR) {
        _setRoleAdmin(role, adminRole);
    }

    // AccessControlEnumerable is AccessControl, and also has the following functions :
    // hasRole(bytes32 role, address account) -> bool
    // getRoleAdmin(bytes32 role) -> bytes32
    // grantRole(bytes32 role, address account)
    // revokeRole(bytes32 role, address account)
    // renounceRole(bytes32 role, address account)

    /// @notice revokes a role from address
    /// @param role the role to revoke
    /// @param account the address to revoke the role from
    function guardianRevokeRole(
        bytes32 role,
        address account
    ) external onlyRole(CoreRoles.GUARDIAN) {
        require(
            role != CoreRoles.GOVERNOR,
            "Core: guardian cannot revoke governor"
        );

        // External call because this contract is appointed as a governor and has access to revoke
        this.revokeRole(role, account);
    }
}
