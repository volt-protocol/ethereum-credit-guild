//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {Addresses} from "@test/proposals/Addresses.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {VoltGovernor} from "@src/governance/VoltGovernor.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {VoltVetoGovernor} from "@src/governance/VoltVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {VoltTimelockController} from "@src/governance/VoltTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";

contract Proposal_0 is Proposal {
    string public name = "Proposal_0";

    function deploy(Addresses addresses) public {
        // Core
        {
            Core core = new Core();
            addresses.addMainnet("CORE", address(core));
        }

        // ProfitManager
        {
            ProfitManager profitManager = new ProfitManager(addresses.mainnet("CORE"));
            addresses.addMainnet("PROFIT_MANAGER", address(profitManager));
        }

        // Tokens & minting
        {
            CreditToken credit = new CreditToken(addresses.mainnet("CORE"));
            GuildToken guild = new GuildToken(
                addresses.mainnet("CORE"),
                addresses.mainnet("PROFIT_MANAGER"),
                address(credit)
            );
            RateLimitedMinter rateLimitedCreditMinter = new RateLimitedMinter(
                addresses.mainnet("CORE"),
                address(credit),
                CoreRoles.RATE_LIMITED_CREDIT_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                2_000_000e18 // bufferCap
            );
            RateLimitedMinter rateLimitedGuildMinter = new RateLimitedMinter(
                addresses.mainnet("CORE"),
                address(credit),
                CoreRoles.RATE_LIMITED_GUILD_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                700_000_000e18 // bufferCap
            );
            SurplusGuildMinter guildMinter = new SurplusGuildMinter(
                addresses.mainnet("CORE"),
                addresses.mainnet("PROFIT_MANAGER"),
                address(credit),
                address(guild),
                address(rateLimitedGuildMinter),
                5e18, // ratio of GUILD minted per CREDIT staked
                0.1e18 // negative interest rate of GUILD borrowed
            );

            addresses.addMainnet("ERC20_CREDIT", address(credit));
            addresses.addMainnet("ERC20_GUILD", address(guild));
            addresses.addMainnet("RATE_LIMITED_CREDIT_MINTER", address(rateLimitedCreditMinter));
            addresses.addMainnet("RATE_LIMITED_GUILD_MINTER", address(rateLimitedGuildMinter));
            addresses.addMainnet("SURPLUS_GUILD_MINTER", address(guildMinter));
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
                2_500_000e18, // initialProposalThreshold
                10_000_000e18 // initialQuorum
            );
            VoltVetoGovernor vetoGovernor = new VoltVetoGovernor(
                addresses.mainnet("CORE"),
                address(timelock),
                addresses.mainnet("ERC20_CREDIT"),
                2_500_000e18 // initialQuorum
            );
            LendingTermOffboarding termOffboarding = new LendingTermOffboarding(
                addresses.mainnet("CORE"),
                addresses.mainnet("ERC20_GUILD"),
                5_000_000e18 // quorum
            );

            addresses.addMainnet("TIMELOCK", address(timelock));
            addresses.addMainnet("GOVERNOR", address(governor));
            addresses.addMainnet("VETO_GOVERNOR", address(vetoGovernor));
            addresses.addMainnet("LENDING_TERM_OFFBOARDING", address(termOffboarding));
        }

        // Terms & Auction House
        {
            SimplePSM psm = new SimplePSM(
                addresses.mainnet("CORE"),
                addresses.mainnet("PROFIT_MANAGER"),
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"),
                addresses.mainnet("ERC20_CREDIT"),
                addresses.mainnet("ERC20_USDC")
            );
            AuctionHouse auctionHouse = new AuctionHouse(
                addresses.mainnet("CORE"),
                650, // midPoint = 10m50s
                1800, // auctionDuration = 30m
                0.1e18 // dangerPenalty = 10%
            );
            LendingTerm termUSDC1 = new LendingTerm(
                addresses.mainnet("CORE"),
                addresses.mainnet("PROFIT_MANAGER"),
                addresses.mainnet("ERC20_GUILD"),
                address(auctionHouse),
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"),
                addresses.mainnet("ERC20_CREDIT"),
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet("ERC20_USDC"),
                    maxDebtPerCollateralToken: 1e30, // 1 CREDIT per USDC collateral + 12 decimals correction
                    interestRate: 0, // 0%
                    maxDelayBetweenPartialRepay: 0,// no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    callFee: 0.01e18, // 1%
                    callPeriod: 120, // 2 minutes
                    hardCap: 2_000_000e18, // max 2M CREDIT issued
                    ltvBuffer: 0.05e18 // 5% overcollateralization needed
                })
            );
            LendingTerm termSDAI1 = new LendingTerm(
                addresses.mainnet("CORE"),
                addresses.mainnet("PROFIT_MANAGER"),
                addresses.mainnet("ERC20_GUILD"),
                address(auctionHouse),
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"),
                addresses.mainnet("ERC20_CREDIT"),
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet("ERC20_SDAI"),
                    maxDebtPerCollateralToken: 1e18, // 1 CREDIT per SDAI collateral + no decimals correction
                    interestRate: 0.03e18, // 3%
                    maxDelayBetweenPartialRepay: 0,// no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    callFee: 0.01e18, // 1%
                    callPeriod: 120, // 2 minutes
                    hardCap: 2_000_000e18, // max 2M CREDIT issued
                    ltvBuffer: 0 // loans do not require overcollateralization (sDAI is itself worth more than 1 DAI)
                })
            );
            addresses.addMainnet("PSM_USDC", address(psm));
            addresses.addMainnet("AUCTION_HOUSE_1", address(auctionHouse));
            addresses.addMainnet("TERM_USDC_1", address(termUSDC1));
            addresses.addMainnet("TERM_SDAI_1", address(termSDAI1));
        }
    }

    function afterDeploy(Addresses addresses, address deployer) public {
        Core core = Core(addresses.mainnet("CORE"));

        // grant roles to smart contracts
        // GOVERNOR
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet("TIMELOCK"));
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet("LENDING_TERM_OFFBOARDING"));

        // GUARDIAN
        core.grantRole(CoreRoles.GUARDIAN, addresses.mainnet("TEAM_MULTISIG"));

        // CREDIT_MINTER
        core.grantRole(CoreRoles.CREDIT_MINTER, addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"));

        // RATE_LIMITED_CREDIT_MINTER
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, addresses.mainnet("PSM_USDC"));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, addresses.mainnet("TERM_USDC_1"));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, addresses.mainnet("TERM_SDAI_1"));

        // GUILD_MINTER
        core.grantRole(CoreRoles.GUILD_MINTER, addresses.mainnet("RATE_LIMITED_GUILD_MINTER"));

        // RATE_LIMITED_GUILD_MINTER
        core.grantRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, addresses.mainnet("SURPLUS_GUILD_MINTER"));

        // GAUGE_ADD
        core.grantRole(CoreRoles.GAUGE_ADD, addresses.mainnet("TIMELOCK"));
        core.grantRole(CoreRoles.GAUGE_ADD, deployer);

        // GAUGE_REMOVE
        core.grantRole(CoreRoles.GAUGE_REMOVE, addresses.mainnet("TIMELOCK"));
        core.grantRole(CoreRoles.GAUGE_REMOVE, addresses.mainnet("LENDING_TERM_OFFBOARDING"));

        // GAUGE_PARAMETERS
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, addresses.mainnet("TIMELOCK"));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, deployer);

        // GAUGE_PNL_NOTIFIER
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, addresses.mainnet("TERM_USDC_1"));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, addresses.mainnet("TERM_SDAI_1"));

        // GUILD_GOVERNANCE_PARAMETERS
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, addresses.mainnet("TIMELOCK"));
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);

        // GUILD_SURPLUS_BUFFER_WITHDRAW
        core.grantRole(CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW, addresses.mainnet("SURPLUS_GUILD_MINTER"));

        // CREDIT_GOVERNANCE_PARAMETERS
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, addresses.mainnet("TIMELOCK"));
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);

        // CREDIT_REBASE_PARAMETERS
        core.grantRole(CoreRoles.CREDIT_REBASE_PARAMETERS, addresses.mainnet("TIMELOCK"));

        // TIMELOCK_PROPOSER
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, addresses.mainnet("GOVERNOR"));
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, addresses.mainnet("TEAM_MULTISIG"));

        // TIMELOCK_EXECUTOR
        core.grantRole(CoreRoles.TIMELOCK_EXECUTOR, address(0)); // anyone can execute

        // TIMELOCK_CANCELLER
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, addresses.mainnet("VETO_GOVERNOR"));
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, addresses.mainnet("TEAM_MULTISIG"));

        // Configuration
        ProfitManager(addresses.mainnet("PROFIT_MANAGER")).initializeReferences(
            addresses.mainnet("ERC20_CREDIT"),
            addresses.mainnet("ERC20_GUILD")
        );
        ProfitManager(addresses.mainnet("PROFIT_MANAGER")).setProfitSharingConfig(
            0.1e18, // 10% surplusBufferSplit
            0.9e18, // 90% creditSplit
            0, // guildSplit
            0, // otherSplit
            address(0) // otherRecipient
        );
        GuildToken(addresses.mainnet("ERC20_GUILD")).setCanExceedMaxGauges(
            addresses.mainnet("SURPLUS_GUILD_MINTER"),
            true
        );
        GuildToken(addresses.mainnet("ERC20_GUILD")).setMaxGauges(10);
        GuildToken(addresses.mainnet("ERC20_GUILD")).addGauge(
            1,
            addresses.mainnet("TERM_USDC_1")
        );
        GuildToken(addresses.mainnet("ERC20_GUILD")).addGauge(
            1,
            addresses.mainnet("TERM_SDAI_1")
        );
        GuildToken(addresses.mainnet("ERC20_GUILD")).setMaxDelegates(10);
        CreditToken(addresses.mainnet("ERC20_CREDIT")).setMaxDelegates(10);

        // Mint the first CREDIT tokens and enter rebase
        // Doing this with a non-dust balance ensures the share price internally
        // to the CreditToken has a reasonable size.
        {
            ERC20 usdc = ERC20(addresses.mainnet("ERC20_USDC"));
            SimplePSM psm = SimplePSM(addresses.mainnet("PSM_USDC"));
            CreditToken credit = CreditToken(addresses.mainnet("ERC20_CREDIT"));
            if (usdc.balanceOf(deployer) >= 100e6) {
                usdc.approve(
                    address(psm),
                    100e6
                );
                psm.mint(deployer, 100e6);
                credit.enterRebase();
            }
        }

        // deployer renounces governor role
        core.renounceRole(CoreRoles.GOVERNOR, deployer);
        core.renounceRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GAUGE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GAUGE_ADD, deployer);
    }

    function run(Addresses addresses, address deployer) public pure {}

    function teardown(Addresses addresses, address deployer) public pure {}

    function validate(Addresses addresses, address deployer) public pure {}
}
