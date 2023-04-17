// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {PostProposalCheck} from "@test/integration/proposal-checks/PostProposalCheck.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

contract IntegrationTestRoles is PostProposalCheck {
    function testMainnetRoles() public {
        Core core = Core(addresses.mainnet("CORE"));

        // GOVERNOR
        /*assertEq(core.getRoleAdmin(CoreRoles.GOVERNOR), CoreRoles.GOVERNOR);
        assertEq(core.getRoleMemberCount(CoreRoles.GOVERNOR), 2);
        assertEq(
            core.getRoleMember(CoreRoles.GOVERNOR, 0),
            addresses.mainnet("CORE")
        );
        assertEq(
            core.getRoleMember(CoreRoles.GOVERNOR, 1),
            addresses.mainnet("TIMELOCK_CONTROLLER")
        );

        // GUARDIAN
        assertEq(core.getRoleAdmin(CoreRoles.GUARDIAN), CoreRoles.GOVERNOR);
        assertEq(core.getRoleMemberCount(CoreRoles.GUARDIAN), 1);
        assertEq(
            core.getRoleMember(CoreRoles.GUARDIAN, 0),
            addresses.mainnet("TEAM_MULTISIG")
        );

        // CREDIT_MINTER
        assertEq(core.getRoleAdmin(CoreRoles.CREDIT_MINTER), CoreRoles.GOVERNOR);
        assertEq(core.getRoleMemberCount(CoreRoles.CREDIT_MINTER), 1);
        assertEq(
            core.getRoleMember(CoreRoles.CREDIT_MINTER, 0),
            addresses.mainnet("RATE_LIMITED_CREDIT_MINTER")
        );

        /// TIMELOCK ROLES
        /// Proposer
        assertEq(
            core.getRoleAdmin(CoreRoles.TIMELOCK_PROPOSER),
            CoreRoles.GOVERNOR
        );
        assertEq(core.getRoleMemberCount(CoreRoles.TIMELOCK_PROPOSER), 1);
        assertEq(
            core.getRoleMember(CoreRoles.TIMELOCK_PROPOSER, 0),
            addresses.mainnet("TEAM_MULTISIG")
        );
        /// Executor
        assertEq(
            core.getRoleAdmin(CoreRoles.TIMELOCK_EXECUTOR),
            CoreRoles.GOVERNOR
        );
        assertEq(core.getRoleMemberCount(CoreRoles.TIMELOCK_EXECUTOR), 1);
        assertEq(
            core.getRoleMember(CoreRoles.TIMELOCK_EXECUTOR, 0),
            address(0)
        );
        /// Canceller
        assertEq(
            core.getRoleAdmin(CoreRoles.TIMELOCK_CANCELLER),
            CoreRoles.GOVERNOR
        );
        assertEq(core.getRoleMemberCount(CoreRoles.TIMELOCK_CANCELLER), 1);
        assertEq(
            core.getRoleMember(CoreRoles.TIMELOCK_CANCELLER, 0),
            addresses.mainnet("TEAM_MULTISIG")
        );*/
    }
}
