//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.13;

import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {Addresses} from "@test/proposals/Addresses.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {VoltGovernor} from "@src/governance/VoltGovernor.sol";
import {VoltTimelockController} from "@src/governance/VoltTimelockController.sol";
import {VoltVetoGovernor} from "@src/governance/VoltVetoGovernor.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";

contract Proposal_0 is Proposal {
    string public name = "Proposal_0";

    function deploy(Addresses addresses) public {
        Core core = new Core();
        CreditToken credit = new CreditToken(address(core));
        GuildToken guild = new GuildToken(
            address(core),
            address(credit),
            7 days, // gaugeCycleLength,
            1 days // incrementFreezeWindow
        );
        VoltTimelockController timelock = new VoltTimelockController(
            address(core),
            3 days
        );
        VoltGovernor governor = new VoltGovernor(
            address(core),
            address(timelock),
            address(guild),
            0, // initialVotingDelay
            7000 * 3, // initialVotingPeriod (~7000 blocks/day)
            2_500_000 ether, // initialProposalThreshold
            10_000_000 ether // initialQuorum
        );
        VoltVetoGovernor vetoGovernor = new VoltVetoGovernor(
            address(core),
            address(timelock),
            address(credit),
            2_500_000 ether // initialQuorum
        );
        RateLimitedCreditMinter rateLimitedCreditMinter = new RateLimitedCreditMinter(
            address(core),
            address(credit),
            0, // maxRateLimitPerSecond
            0, // rateLimitPerSecond
            2_000_000 ether // bufferCap
        );

        addresses.addMainnet("CORE", address(core));
        addresses.addMainnet("ERC20_CREDIT", address(credit));
        addresses.addMainnet("ERC20_GUILD", address(guild));
        addresses.addMainnet("TIMELOCK", address(timelock));
        addresses.addMainnet("GOVERNOR", address(governor));
        addresses.addMainnet("VETO_GOVERNOR", address(vetoGovernor));
        addresses.addMainnet("RATE_LIMITED_CREDIT_MINTER", address(rateLimitedCreditMinter));
    }

    function afterDeploy(Addresses addresses, address deployer) public {
        Core core = Core(addresses.mainnet("CORE"));

        // grant roles to smart contracts
        // GOVERNOR
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet("TIMELOCK"));

        // GUARDIAN
        core.grantRole(CoreRoles.GUARDIAN, addresses.mainnet("TEAM_MULTISIG"));

        // CREDIT_MINTER
        // no contracts should have this role yet

        // RATE_LIMITED_CREDIT_MINTER
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"));

        // GUILD_MINTER
        // no contracts should have this role yet

        // GAUGE_ADD
        core.grantRole(CoreRoles.GAUGE_ADD, addresses.mainnet("TIMELOCK"));

        // GAUGE_REMOVE
        core.grantRole(CoreRoles.GAUGE_REMOVE, addresses.mainnet("TIMELOCK"));

        // GAUGE_PARAMETERS
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, addresses.mainnet("TIMELOCK"));

        // GAUGE_PNL_NOTIFIER
        // no contracts should have this role yet

        // TIMELOCK_PROPOSER
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, addresses.mainnet("GOVERNOR"));
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, addresses.mainnet("TEAM_MULTISIG"));

        // TIMELOCK_EXECUTOR
        core.grantRole(CoreRoles.TIMELOCK_EXECUTOR, address(0)); // anyone can execute

        // TIMELOCK_CANCELLER
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, addresses.mainnet("VETO_GOVERNOR"));
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, addresses.mainnet("TEAM_MULTISIG"));

        // deployer renounces governor role
        core.renounceRole(CoreRoles.GOVERNOR, deployer);
    }

    function run(Addresses addresses, address deployer) public pure {}

    function teardown(Addresses addresses, address deployer) public pure {}

    function validate(Addresses addresses, address deployer) public pure {}
}
