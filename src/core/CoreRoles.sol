// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

/**
@title Ethereum Credit Guild ACL Roles
@notice Holds a complete list of all roles which can be held by contracts inside the Ethereum Credit Guild.
*/
library CoreRoles {
    /// ----------- Core roles for access control --------------

    /// @notice the all-powerful role. Controls all other roles and protocol functionality.
    bytes32 internal constant GOVERNOR = keccak256("GOVERNOR_ROLE");

    /// @notice the protector role. Can pause contracts and revoke roles in an emergency.
    bytes32 internal constant GUARDIAN = keccak256("GUARDIAN_ROLE");

    /// ----------- Token supply roles -------------------------

    /// @notice can mint CREDIT arbitrarily
    bytes32 internal constant CREDIT_MINTER = keccak256("CREDIT_MINTER_ROLE");

    /// @notice can mint CREDIT within rate limits
    bytes32 internal constant RATE_LIMITED_CREDIT_MINTER =
        keccak256("RATE_LIMITED_CREDIT_MINTER_ROLE");

    /// @notice can mint GUILD arbitrarily
    bytes32 internal constant GUILD_MINTER = keccak256("GUILD_MINTER_ROLE");

    /// ----------- GUILD Token Gauge Management ---------------

    /// @notice can manage add new gauges to the system
    bytes32 internal constant GAUGE_ADD = keccak256("GAUGE_ADD_ROLE");

    /// @notice can remove gauges from the system
    bytes32 internal constant GAUGE_REMOVE = keccak256("GAUGE_REMOVE_ROLE");

    /// @notice can manage gauge parameters (max gauges, individual cap)
    bytes32 internal constant GAUGE_PARAMETERS =
        keccak256("GAUGE_PARAMETERS_ROLE");

    /// @notice can notify of profits & losses in a given gauge
    bytes32 internal constant GAUGE_PNL_NOTIFIER =
        keccak256("GAUGE_PNL_NOTIFIER_ROLE");

    /// ----------- Lending Term Management --------------------

    /// @notice can offboard a lending term from the system (force-close loans)
    bytes32 internal constant TERM_OFFBOARD = keccak256("TERM_OFFBOARD_ROLE");

    /// @notice can set the hardcap of a lending term
    bytes32 internal constant TERM_HARDCAP = keccak256("TERM_HARDCAP_ROLE");

    /// ----------- Timelock management ------------------------
    /// The hashes are the same as OpenZeppelins's roles in TimelockController

    /// @notice can propose new actions in timelocks
    bytes32 internal constant TIMELOCK_PROPOSER = keccak256("PROPOSER_ROLE");
    /// @notice can execute actions in timelocks after their delay
    bytes32 internal constant TIMELOCK_EXECUTOR = keccak256("EXECUTOR_ROLE");
    /// @notice can cancel actions in timelocks
    bytes32 internal constant TIMELOCK_CANCELLER = keccak256("CANCELLER_ROLE");
}
