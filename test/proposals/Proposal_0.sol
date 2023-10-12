//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {Addresses} from "@test/proposals/Addresses.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRef} from "@src/core/CoreRef.sol";
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
import {NameLib as strings} from "@src/utils/NameLib.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {VoltTimelockController} from "@src/governance/VoltTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";

contract Proposal_0 is Proposal {
    string public name = "Proposal_0";

    uint256 public constant guildInitialSupply = 1_000_000_000e18;

    /// Credit Veto DAO
    uint256 public constant initialQuorumVetoDao = 2_500_000e18;

    /// Guild Governor DAO
    uint256 public constant initialQuorum = 10_000_000e18; // initialQuorum
    uint256 public constant initialVotingDelay = 0; // initialVotingDelay
    uint256 public constant initialVotingPeriod = 7000 * 3; // initialVotingPeriod (~7000 blocks/day)
    uint256 public constant initialProposalThreshold = 2_500_000e18; // initialProposalThreshold

    function deploy(Addresses addresses) public {
        // Core
        {
            Core core = new Core();
            addresses.addMainnet(strings.core, address(core));
        }

        // ProfitManager
        {
            ProfitManager profitManager = new ProfitManager(
                addresses.mainnet(strings.core)
            );
            addresses.addMainnet(strings.profitManager, address(profitManager));
        }

        // Tokens & minting
        {
            CreditToken credit = new CreditToken(addresses.mainnet(strings.core));
            GuildToken guild = new GuildToken(
                addresses.mainnet(strings.core),
                addresses.mainnet(strings.profitManager),
                address(credit)
            );
            RateLimitedMinter rateLimitedCreditMinter = new RateLimitedMinter(
                addresses.mainnet(strings.core),
                address(credit),
                CoreRoles.RATE_LIMITED_CREDIT_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                2_000_000e18 // bufferCap
            );
            RateLimitedMinter rateLimitedGuildMinter = new RateLimitedMinter(
                addresses.mainnet(strings.core),
                address(guild),
                CoreRoles.RATE_LIMITED_GUILD_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                1_000_000_000e18 // bufferCap
            );
            SurplusGuildMinter guildMinter = new SurplusGuildMinter(
                addresses.mainnet(strings.core),
                addresses.mainnet(strings.profitManager),
                address(credit),
                address(guild),
                address(rateLimitedGuildMinter),
                5e18, // ratio of GUILD minted per CREDIT staked
                0.1e18 // negative interest rate of GUILD borrowed
            );

            addresses.addMainnet(strings.creditToken, address(credit));
            addresses.addMainnet(strings.guildToken, address(guild));
            addresses.addMainnet(
                strings.rlcm,
                address(rateLimitedCreditMinter)
            );
            addresses.addMainnet(
                "RATE_LIMITED_GUILD_MINTER",
                address(rateLimitedGuildMinter)
            );
            addresses.addMainnet(strings.guildMinter, address(guildMinter));
        }

        // Auction House & LendingTerm Implementation V1
        {
            AuctionHouse auctionHouse = new AuctionHouse(
                addresses.mainnet(strings.core),
                650, // midPoint = 10m50s
                1800 // auctionDuration = 30m
            );

            LendingTerm termV1 = new LendingTerm();

            addresses.addMainnet(strings.auctionHouse, address(auctionHouse));
            addresses.addMainnet(strings.lendingTerm, address(termV1));
        }

        // Governance
        {
            VoltTimelockController timelock = new VoltTimelockController(
                addresses.mainnet(strings.core),
                3 days
            );
            VoltGovernor governor = new VoltGovernor(
                addresses.mainnet(strings.core),
                address(timelock),
                addresses.mainnet(strings.guildToken),
                0, // initialVotingDelay
                7000 * 3, // initialVotingPeriod (~7000 blocks/day)
                2_500_000e18, // initialProposalThreshold
                10_000_000e18 // initialQuorum
            );

            VoltVetoGovernor vetoGovernor = new VoltVetoGovernor(
                addresses.mainnet(strings.core),
                address(timelock),
                addresses.mainnet(strings.creditToken),
                2_500_000e18 // initialQuorum
            );
            LendingTermOffboarding termOffboarding = new LendingTermOffboarding(
                addresses.mainnet(strings.core),
                addresses.mainnet(strings.guildToken),
                5_000_000e18 // quorum
            );
            LendingTermOnboarding termOnboarding = new LendingTermOnboarding(
                addresses.mainnet(strings.lendingTerm), // _lendingTermImplementation
                LendingTerm.LendingTermReferences({
                    profitManager: addresses.mainnet(strings.profitManager),
                    guildToken: addresses.mainnet(strings.guildToken),
                    auctionHouse: addresses.mainnet(strings.auctionHouse),
                    creditMinter: addresses.mainnet(
                        strings.rlcm
                    ),
                    creditToken: addresses.mainnet(strings.creditToken)
                }), /// _lendingTermReferences
                1, // _gaugeType
                addresses.mainnet(strings.core), // _core
                addresses.mainnet(strings.timelock), // _timelock
                initialVotingDelay, // initialVotingDelay
                initialVotingPeriod, // initialVotingPeriod (~7000 blocks/day)
                2_500_000e18, // initialProposalThreshold
                10_000_000e18 // initialQuorum
            );

            addresses.addMainnet(strings.timelock, address(timelock));
            addresses.addMainnet(strings.governor, address(governor));
            addresses.addMainnet(strings.vetoGovernor, address(vetoGovernor));
            addresses.addMainnet(
                "LENDING_TERM_OFFBOARDING",
                address(termOffboarding)
            );
            addresses.addMainnet(
                "LENDING_TERM_ONBOARDING",
                address(termOnboarding)
            );
        }

        // Terms & PSM
        {
            SimplePSM psm = new SimplePSM(
                addresses.mainnet(strings.core),
                addresses.mainnet(strings.profitManager),
                addresses.mainnet(strings.rlcm),
                addresses.mainnet(strings.creditToken),
                addresses.mainnet("ERC20_USDC")
            );

            LendingTermOnboarding termOnboarding = LendingTermOnboarding(
                payable(addresses.mainnet("LENDING_TERM_ONBOARDING"))
            );
            address termUSDC1 = termOnboarding.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet("ERC20_USDC"),
                    maxDebtPerCollateralToken: 1e30, // 1 CREDIT per USDC collateral + 12 decimals correction
                    interestRate: 0, // 0%
                    maxDelayBetweenPartialRepay: 0, // no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    hardCap: 2_000_000e18 // max 2M CREDIT issued
                })
            );
            address termSDAI1 = termOnboarding.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet("ERC20_SDAI"),
                    maxDebtPerCollateralToken: 1e18, // 1 CREDIT per SDAI collateral + no decimals correction
                    interestRate: 0.03e18, // 3%
                    maxDelayBetweenPartialRepay: 0, // no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    hardCap: 2_000_000e18 // max 2M CREDIT issued
                })
            );

            addresses.addMainnet("PSM_USDC", address(psm));
            addresses.addMainnet("TERM_USDC_1", termUSDC1);
            addresses.addMainnet("TERM_SDAI_1", termSDAI1);
        }
    }

    function afterDeploy(Addresses addresses, address deployer) public {
        Core core = Core(addresses.mainnet(strings.core));

        // grant roles to smart contracts
        // GOVERNOR
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet(strings.timelock));
        core.grantRole(
            CoreRoles.GOVERNOR,
            addresses.mainnet("LENDING_TERM_OFFBOARDING")
        );

        // GUARDIAN
        core.grantRole(CoreRoles.GUARDIAN, addresses.mainnet("TEAM_MULTISIG"));

        // CREDIT_MINTER
        core.grantRole(
            CoreRoles.CREDIT_MINTER,
            addresses.mainnet(strings.rlcm)
        );

        // RATE_LIMITED_CREDIT_MINTER
        core.grantRole(
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            addresses.mainnet("PSM_USDC")
        );
        core.grantRole(
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            addresses.mainnet("TERM_USDC_1")
        );
        core.grantRole(
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            addresses.mainnet("TERM_SDAI_1")
        );

        // GUILD_MINTER
        core.grantRole(
            CoreRoles.GUILD_MINTER,
            addresses.mainnet("RATE_LIMITED_GUILD_MINTER")
        );

        // RATE_LIMITED_GUILD_MINTER
        core.grantRole(
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            addresses.mainnet(strings.guildMinter)
        );

        // GAUGE_ADD
        core.grantRole(CoreRoles.GAUGE_ADD, addresses.mainnet(strings.timelock));
        core.grantRole(CoreRoles.GAUGE_ADD, deployer);

        // GAUGE_REMOVE
        core.grantRole(CoreRoles.GAUGE_REMOVE, addresses.mainnet(strings.timelock));
        core.grantRole(
            CoreRoles.GAUGE_REMOVE,
            addresses.mainnet("LENDING_TERM_OFFBOARDING")
        );

        // GAUGE_PARAMETERS
        core.grantRole(
            CoreRoles.GAUGE_PARAMETERS,
            addresses.mainnet(strings.timelock)
        );
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, deployer);

        // GAUGE_PNL_NOTIFIER
        core.grantRole(
            CoreRoles.GAUGE_PNL_NOTIFIER,
            addresses.mainnet("TERM_USDC_1")
        );
        core.grantRole(
            CoreRoles.GAUGE_PNL_NOTIFIER,
            addresses.mainnet("TERM_SDAI_1")
        );

        // GUILD_GOVERNANCE_PARAMETERS
        core.grantRole(
            CoreRoles.GUILD_GOVERNANCE_PARAMETERS,
            addresses.mainnet(strings.timelock)
        );
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);

        // GUILD_SURPLUS_BUFFER_WITHDRAW
        core.grantRole(
            CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW,
            addresses.mainnet(strings.guildMinter)
        );

        // CREDIT_GOVERNANCE_PARAMETERS
        core.grantRole(
            CoreRoles.CREDIT_GOVERNANCE_PARAMETERS,
            addresses.mainnet(strings.timelock)
        );
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);

        // CREDIT_REBASE_PARAMETERS
        core.grantRole(
            CoreRoles.CREDIT_REBASE_PARAMETERS,
            addresses.mainnet(strings.timelock)
        );

        // TIMELOCK_PROPOSER
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            addresses.mainnet(strings.governor)
        );
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            addresses.mainnet("LENDING_TERM_ONBOARDING")
        );
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            addresses.mainnet("TEAM_MULTISIG")
        );

        // TIMELOCK_EXECUTOR
        core.grantRole(CoreRoles.TIMELOCK_EXECUTOR, address(0)); // anyone can execute

        // TIMELOCK_CANCELLER
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            addresses.mainnet(strings.vetoGovernor)
        );
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            addresses.mainnet("TEAM_MULTISIG")
        );

        // Configuration
        ProfitManager(addresses.mainnet(strings.profitManager)).initializeReferences(
            addresses.mainnet(strings.creditToken),
            addresses.mainnet(strings.guildToken)
        );
        ProfitManager(addresses.mainnet(strings.profitManager))
            .setProfitSharingConfig(
                0.1e18, // 10% surplusBufferSplit
                0.9e18, // 90% creditSplit
                0, // guildSplit
                0, // otherSplit
                address(0) // otherRecipient
            );
        GuildToken(addresses.mainnet(strings.guildToken)).setCanExceedMaxGauges(
            addresses.mainnet(strings.guildMinter),
            true
        );
        GuildToken(addresses.mainnet(strings.guildToken)).setMaxGauges(10);
        GuildToken(addresses.mainnet(strings.guildToken)).addGauge(
            1,
            addresses.mainnet("TERM_USDC_1")
        );
        GuildToken(addresses.mainnet(strings.guildToken)).addGauge(
            1,
            addresses.mainnet("TERM_SDAI_1")
        );
        GuildToken(addresses.mainnet(strings.guildToken)).setMaxDelegates(10);
        CreditToken(addresses.mainnet(strings.creditToken)).setMaxDelegates(10);

        // Mint the first CREDIT tokens and enter rebase
        // Doing this with a non-dust balance ensures the share price internally
        // to the CreditToken has a reasonable size.
        {
            ERC20 usdc = ERC20(addresses.mainnet("ERC20_USDC"));
            SimplePSM psm = SimplePSM(addresses.mainnet("PSM_USDC"));
            CreditToken credit = CreditToken(addresses.mainnet(strings.creditToken));
            if (usdc.balanceOf(deployer) >= 100e6) {
                usdc.approve(address(psm), 100e6);
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

    function validate(Addresses addresses, address deployer) public {
        /// TODO ensure all contracts are linked together properly
        Core core = Core(addresses.mainnet(strings.core));
        {
            SimplePSM psm = SimplePSM(addresses.mainnet("PSM_USDC"));
            LendingTerm term1 = LendingTerm(addresses.mainnet("TERM_USDC_1"));
            LendingTerm term2 = LendingTerm(addresses.mainnet("TERM_USDC_2"));
            CreditToken credit = CreditToken(addresses.mainnet(strings.creditToken));
            GuildToken guild = GuildToken(addresses.mainnet(strings.guildToken));
            LendingTermOnboarding onboarder = LendingTermOnboarding(
                payable(addresses.mainnet("LENDING_TERM_ONBOARDING"))
            );
            LendingTermOffboarding offboarding = LendingTermOffboarding(
                payable(addresses.mainnet("LENDING_TERM_OFFBOARDING"))
            );
            VoltTimelockController timelock = VoltTimelockController(
                payable(addresses.mainnet(strings.timelock))
            );
            SurplusGuildMinter sgm = SurplusGuildMinter(
                addresses.mainnet(strings.guildMinter)
            );
            ProfitManager mgr = ProfitManager(
                addresses.mainnet(strings.profitManager)
            );
            RateLimitedMinter rateLimitedCreditMinter = RateLimitedMinter(
                addresses.mainnet(strings.rlcm)
            );
            RateLimitedMinter rateLimitedGuildMinter = RateLimitedMinter(
                addresses.mainnet("RATE_LIMITED_GUILD_MINTER")
            );

            assertEq(address(core), address(mgr.core()));
            assertEq(address(core), address(sgm.core()));
            assertEq(address(core), address(psm.core()));
            assertEq(address(core), address(guild.core()));
            assertEq(address(core), address(term1.core()));
            assertEq(address(core), address(term2.core()));
            assertEq(address(core), address(credit.core()));
            assertEq(address(core), address(timelock.core()));
            assertEq(address(core), address(onboarder.core()));
            assertEq(address(core), address(offboarding.core()));
            assertEq(address(core), address(rateLimitedGuildMinter.core()));
            assertEq(address(core), address(rateLimitedCreditMinter.core()));
        }
    }
}
