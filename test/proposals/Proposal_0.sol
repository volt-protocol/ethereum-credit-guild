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
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {LendingTermUSDC} from "@src/loan/LendingTermUSDC.sol";

contract Proposal_0 is Proposal {
    string public name = "Proposal_0";

    function deploy(Addresses addresses) public {
        // Core
        {
            Core core = new Core();
            addresses.addMainnet("CORE", address(core));
        }

        // Tokens & minting
        {
            CreditToken credit = new CreditToken(addresses.mainnet("CORE"));
            GuildToken guild = new GuildToken(
                addresses.mainnet("CORE"),
                address(credit),
                7 days, // gaugeCycleLength,
                1 days // incrementFreezeWindow
            );
            RateLimitedCreditMinter rateLimitedCreditMinter = new RateLimitedCreditMinter(
                addresses.mainnet("CORE"),
                address(credit),
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                2_000_000 ether // bufferCap
            );
            addresses.addMainnet("ERC20_CREDIT", address(credit));
            addresses.addMainnet("ERC20_GUILD", address(guild));
            addresses.addMainnet("RATE_LIMITED_CREDIT_MINTER", address(rateLimitedCreditMinter));
        }

        // Governance
        {
            VoltTimelockController timelock = new VoltTimelockController(
                addresses.mainnet("CORE"),
                3 days
            );
            VoltGovernor governor = new VoltGovernor(
                addresses.mainnet("CORE"),
                address(timelock),
                addresses.mainnet("ERC20_GUILD"),
                0, // initialVotingDelay
                7000 * 3, // initialVotingPeriod (~7000 blocks/day)
                2_500_000 ether, // initialProposalThreshold
                10_000_000 ether // initialQuorum
            );
            VoltVetoGovernor vetoGovernor = new VoltVetoGovernor(
                addresses.mainnet("CORE"),
                address(timelock),
                addresses.mainnet("ERC20_CREDIT"),
                2_500_000 ether // initialQuorum
            );
            addresses.addMainnet("TIMELOCK", address(timelock));
            addresses.addMainnet("GOVERNOR", address(governor));
            addresses.addMainnet("VETO_GOVERNOR", address(vetoGovernor));
        }

        // Terms & Auction House
        {
            AuctionHouse auctionHouse = new AuctionHouse(
                addresses.mainnet("CORE"),
                addresses.mainnet("ERC20_GUILD"),
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"),
                addresses.mainnet("ERC20_CREDIT")
            );
            LendingTermUSDC termUsdc1 = new LendingTermUSDC(
                addresses.mainnet("CORE"),
                addresses.mainnet("ERC20_GUILD"),
                address(auctionHouse),
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"),
                addresses.mainnet("ERC20_CREDIT"),
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet("ERC20_USDC"),
                    creditPerCollateralToken: 0.98e30, // 0.98 CREDIT per USDC collateral + 12 decimals of correction
                    interestRate: 0.02e18, // 2%
                    callFee: 0.02e18, // 2%
                    callPeriod: 600, // 10 minutes
                    hardCap: 2_000_000e18, // max 2M CREDIT issued
                    ltvBuffer: 0.95e18 // 95%
                })
            );
            addresses.addMainnet("AUCTION_HOUSE_1", address(auctionHouse));
            addresses.addMainnet("TERM_USDC_1", address(termUsdc1));
        }
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
