//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRef} from "@src/core/CoreRef.sol";
import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {Addresses} from "@test/proposals/Addresses.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {VoltGovernor} from "@src/governance/VoltGovernor.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {VoltVetoGovernor} from "@src/governance/VoltVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {NameLib as strings} from "@src/utils/NameLib.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {VoltTimelockController} from "@src/governance/VoltTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {ProtocolConstants as constants} from "@src/utils/ProtocolConstants.sol";

contract Proposal_0 is Proposal {
    string public name = "Proposal_0";

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
            addresses.addMainnet(strings.CORE, address(core));
        }

        // ProfitManager
        {
            ProfitManager profitManager = new ProfitManager(
                addresses.mainnet(strings.CORE)
            );
            addresses.addMainnet(
                strings.PROFIT_MANAGER,
                address(profitManager)
            );
        }

        // Tokens & minting
        {
            CreditToken credit = new CreditToken(
                addresses.mainnet(strings.CORE)
            );
            GuildToken guild = new GuildToken(
                addresses.mainnet(strings.CORE),
                addresses.mainnet(strings.PROFIT_MANAGER),
                address(credit)
            );
            RateLimitedMinter rateLimitedCreditMinter = new RateLimitedMinter(
                addresses.mainnet(strings.CORE),
                address(credit),
                CoreRoles.RATE_LIMITED_CREDIT_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                2_000_000e18 // bufferCap
            );
            RateLimitedMinter rateLimitedGuildMinter = new RateLimitedMinter(
                addresses.mainnet(strings.CORE),
                address(guild),
                CoreRoles.RATE_LIMITED_GUILD_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                1_000_000_000e18 // bufferCap
            );
            SurplusGuildMinter guildMinter = new SurplusGuildMinter(
                addresses.mainnet(strings.CORE),
                addresses.mainnet(strings.PROFIT_MANAGER),
                address(credit),
                address(guild),
                address(rateLimitedGuildMinter),
                5e18, // ratio of GUILD minted per CREDIT staked
                0.1e18 // negative interest rate of GUILD borrowed
            );

            addresses.addMainnet(strings.CREDIT_TOKEN, address(credit));
            addresses.addMainnet(strings.GUILD_TOKEN, address(guild));
            addresses.addMainnet(
                strings.RATE_LIMITED_CREDIT_MINTER,
                address(rateLimitedCreditMinter)
            );
            addresses.addMainnet(
                strings.RATE_LIMITED_GUILD_MINTER,
                address(rateLimitedGuildMinter)
            );
            addresses.addMainnet(
                strings.SURPLUS_GUILD_MINTER,
                address(guildMinter)
            );
        }

        // Auction House & LendingTerm Implementation V1
        {
            AuctionHouse auctionHouse = new AuctionHouse(
                addresses.mainnet(strings.CORE),
                650, // midPoint = 10m50s
                1800 // auctionDuration = 30m
            );

            LendingTerm termV1 = new LendingTerm();

            addresses.addMainnet(strings.AUCTION_HOUSE, address(auctionHouse));
            addresses.addMainnet(strings.LENDING_TERM, address(termV1));
        }

        // Governance
        {
            VoltTimelockController timelock = new VoltTimelockController(
                addresses.mainnet(strings.CORE),
                3 days
            );
            VoltGovernor governor = new VoltGovernor(
                addresses.mainnet(strings.CORE),
                address(timelock),
                addresses.mainnet(strings.GUILD_TOKEN),
                constants.VOTING_DELAY,
                constants.VOTING_PERIOD,
                constants.PROPOSAL_THRESHOLD,
                constants.INITIAL_QUORUM
            );

            VoltVetoGovernor vetoGovernor = new VoltVetoGovernor(
                addresses.mainnet(strings.CORE),
                address(timelock),
                addresses.mainnet(strings.CREDIT_TOKEN),
                constants.INITIAL_QUORUM_VETO_DAO // initialQuorum
            );
            LendingTermOffboarding termOffboarding = new LendingTermOffboarding(
                addresses.mainnet(strings.CORE),
                addresses.mainnet(strings.GUILD_TOKEN),
                constants.LENDING_TERM_OFFBOARDING_QUORUM
            );
            LendingTermOnboarding termOnboarding = new LendingTermOnboarding(
                addresses.mainnet(strings.LENDING_TERM), // _lendingTermImplementation
                LendingTerm.LendingTermReferences({
                    profitManager: addresses.mainnet(strings.PROFIT_MANAGER),
                    guildToken: addresses.mainnet(strings.GUILD_TOKEN),
                    auctionHouse: addresses.mainnet(strings.AUCTION_HOUSE),
                    creditMinter: addresses.mainnet(
                        strings.RATE_LIMITED_CREDIT_MINTER
                    ),
                    creditToken: addresses.mainnet(strings.CREDIT_TOKEN)
                }), /// _lendingTermReferences
                1, // _gaugeType
                addresses.mainnet(strings.CORE), // _core
                addresses.mainnet(strings.TIMELOCK), // _timelock
                initialVotingDelay, // initialVotingDelay
                initialVotingPeriod, // initialVotingPeriod (~7000 blocks/day)
                2_500_000e18, // initialProposalThreshold
                10_000_000e18 // initialQuorum
            );

            addresses.addMainnet(strings.TIMELOCK, address(timelock));
            addresses.addMainnet(strings.GOVERNOR, address(governor));
            addresses.addMainnet(strings.VETO_GOVERNOR, address(vetoGovernor));
            addresses.addMainnet(
                strings.LENDING_TERM_OFFBOARDING,
                address(termOffboarding)
            );
            addresses.addMainnet(
                strings.LENDING_TERM_ONBOARDING,
                address(termOnboarding)
            );
        }

        // Terms & PSM
        {
            SimplePSM psm = new SimplePSM(
                addresses.mainnet(strings.CORE),
                addresses.mainnet(strings.PROFIT_MANAGER),
                addresses.mainnet(strings.RATE_LIMITED_CREDIT_MINTER),
                addresses.mainnet(strings.CREDIT_TOKEN),
                addresses.mainnet(strings.USDC)
            );

            LendingTermOnboarding termOnboarding = LendingTermOnboarding(
                payable(addresses.mainnet(strings.LENDING_TERM_ONBOARDING))
            );
            address termUSDC1 = termOnboarding.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet(strings.USDC),
                    maxDebtPerCollateralToken: constants.MAX_USDC_CREDIT_RATIO, // 0.01 CREDIT per USDC collateral + 12 decimals correction
                    interestRate: 0, // 0%
                    maxDelayBetweenPartialRepay: 0, // no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    hardCap: constants.CREDIT_HARDCAP // max 20k CREDIT issued
                })
            );
            address termSDAI1 = termOnboarding.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet(strings.SDAI),
                    maxDebtPerCollateralToken: constants.MAX_SDAI_CREDIT_RATIO, // 0.01 CREDIT per SDAI collateral + no decimals correction
                    interestRate: 0.03e18, // 3%
                    maxDelayBetweenPartialRepay: 0, // no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    hardCap: constants.CREDIT_HARDCAP // max 20k CREDIT issued
                })
            );

            addresses.addMainnet(strings.PSM_USDC, address(psm));
            addresses.addMainnet(strings.TERM_USDC_1, termUSDC1);
            addresses.addMainnet(strings.TERM_SDAI_1, termSDAI1);
        }
    }

    function afterDeploy(Addresses addresses, address deployer) public {
        Core core = Core(addresses.mainnet(strings.CORE));

        // grant roles to smart contracts
        // GOVERNOR
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet(strings.TIMELOCK));
        core.grantRole(
            CoreRoles.GOVERNOR,
            addresses.mainnet(strings.LENDING_TERM_OFFBOARDING)
        );

        // GUARDIAN
        core.grantRole(
            CoreRoles.GUARDIAN,
            addresses.mainnet(strings.TEAM_MULTISIG)
        );

        // CREDIT_MINTER
        core.grantRole(
            CoreRoles.CREDIT_MINTER,
            addresses.mainnet(strings.RATE_LIMITED_CREDIT_MINTER)
        );

        // RATE_LIMITED_CREDIT_MINTER
        core.grantRole(
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            addresses.mainnet(strings.PSM_USDC)
        );
        core.grantRole(
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            addresses.mainnet(strings.TERM_USDC_1)
        );
        core.grantRole(
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            addresses.mainnet(strings.TERM_SDAI_1)
        );

        // GUILD_MINTER
        core.grantRole(
            CoreRoles.GUILD_MINTER,
            addresses.mainnet(strings.RATE_LIMITED_GUILD_MINTER)
        );

        // RATE_LIMITED_GUILD_MINTER
        core.grantRole(
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            addresses.mainnet(strings.SURPLUS_GUILD_MINTER)
        );

        // RATE_LIMITED_GUILD_MINTER
        core.grantRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, deployer);

        GuildToken(addresses.mainnet(strings.GUILD_TOKEN)).mint(
            addresses.mainnet(strings.TEAM_MULTISIG),
            constants.GUILD_SUPPLY
        );

        // GAUGE_ADD
        core.grantRole(
            CoreRoles.GAUGE_ADD,
            addresses.mainnet(strings.TIMELOCK)
        );
        core.grantRole(CoreRoles.GAUGE_ADD, deployer);

        // GAUGE_REMOVE
        core.grantRole(
            CoreRoles.GAUGE_REMOVE,
            addresses.mainnet(strings.TIMELOCK)
        );
        core.grantRole(
            CoreRoles.GAUGE_REMOVE,
            addresses.mainnet(strings.LENDING_TERM_OFFBOARDING)
        );

        // GAUGE_PARAMETERS
        core.grantRole(
            CoreRoles.GAUGE_PARAMETERS,
            addresses.mainnet(strings.TIMELOCK)
        );
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, deployer);

        // GAUGE_PNL_NOTIFIER
        core.grantRole(
            CoreRoles.GAUGE_PNL_NOTIFIER,
            addresses.mainnet(strings.TERM_USDC_1)
        );
        core.grantRole(
            CoreRoles.GAUGE_PNL_NOTIFIER,
            addresses.mainnet(strings.TERM_SDAI_1)
        );

        // GUILD_GOVERNANCE_PARAMETERS
        core.grantRole(
            CoreRoles.GUILD_GOVERNANCE_PARAMETERS,
            addresses.mainnet(strings.TIMELOCK)
        );
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);

        // GUILD_SURPLUS_BUFFER_WITHDRAW
        core.grantRole(
            CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW,
            addresses.mainnet(strings.SURPLUS_GUILD_MINTER)
        );

        // CREDIT_GOVERNANCE_PARAMETERS
        core.grantRole(
            CoreRoles.CREDIT_GOVERNANCE_PARAMETERS,
            addresses.mainnet(strings.TIMELOCK)
        );
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);

        // CREDIT_REBASE_PARAMETERS
        core.grantRole(
            CoreRoles.CREDIT_REBASE_PARAMETERS,
            addresses.mainnet(strings.TIMELOCK)
        );

        // TIMELOCK_PROPOSER
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            addresses.mainnet(strings.GOVERNOR)
        );
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            addresses.mainnet(strings.LENDING_TERM_ONBOARDING)
        );
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            addresses.mainnet(strings.TEAM_MULTISIG)
        );

        // TIMELOCK_EXECUTOR
        core.grantRole(CoreRoles.TIMELOCK_EXECUTOR, address(0)); // anyone can execute

        // TIMELOCK_CANCELLER
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            addresses.mainnet(strings.VETO_GOVERNOR)
        );
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            addresses.mainnet(strings.TEAM_MULTISIG)
        );

        // Configuration
        ProfitManager(addresses.mainnet(strings.PROFIT_MANAGER))
            .initializeReferences(
                addresses.mainnet(strings.CREDIT_TOKEN),
                addresses.mainnet(strings.GUILD_TOKEN)
            );
        ProfitManager(addresses.mainnet(strings.PROFIT_MANAGER))
            .setProfitSharingConfig(
                constants.SURPLUS_BUFFER_SPLIT, // 10% surplusBufferSplit
                constants.CREDIT_SPLIT, // 90% creditSplit
                constants.GUILD_SPLIT, // guildSplit
                constants.OTHER_SPLIT, // otherSplit
                address(0) // otherRecipient
            );
        GuildToken(addresses.mainnet(strings.GUILD_TOKEN))
            .setCanExceedMaxGauges(
                addresses.mainnet(strings.SURPLUS_GUILD_MINTER),
                true
            );
        GuildToken(addresses.mainnet(strings.GUILD_TOKEN)).setMaxGauges(10);
        GuildToken(addresses.mainnet(strings.GUILD_TOKEN)).addGauge(
            1,
            addresses.mainnet(strings.TERM_USDC_1)
        );
        GuildToken(addresses.mainnet(strings.GUILD_TOKEN)).addGauge(
            1,
            addresses.mainnet(strings.TERM_SDAI_1)
        );
        GuildToken(addresses.mainnet(strings.GUILD_TOKEN)).setMaxDelegates(
            constants.MAX_DELEGATES
        );
        CreditToken(addresses.mainnet(strings.CREDIT_TOKEN)).setMaxDelegates(
            constants.MAX_DELEGATES
        );

        // Mint the first CREDIT tokens and enter rebase
        // Doing this with a non-dust balance ensures the share price internally
        // to the CreditToken has a reasonable size.
        {
            ERC20 usdc = ERC20(addresses.mainnet(strings.USDC));
            SimplePSM psm = SimplePSM(addresses.mainnet(strings.PSM_USDC));
            CreditToken credit = CreditToken(
                addresses.mainnet(strings.CREDIT_TOKEN)
            );
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
        core.renounceRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, deployer);
    }

    function run(Addresses addresses, address deployer) public pure {}

    function teardown(Addresses addresses, address deployer) public pure {}

    function validate(Addresses addresses, address deployer) public {
        /// CORE Verification
        Core core = Core(addresses.mainnet(strings.CORE));
        {
            SimplePSM psm = SimplePSM(addresses.mainnet(strings.PSM_USDC));
            LendingTerm term1 = LendingTerm(
                addresses.mainnet(strings.TERM_USDC_1)
            );
            LendingTerm term2 = LendingTerm(
                addresses.mainnet(strings.TERM_SDAI_1)
            );
            CreditToken credit = CreditToken(
                addresses.mainnet(strings.CREDIT_TOKEN)
            );
            GuildToken guild = GuildToken(
                addresses.mainnet(strings.GUILD_TOKEN)
            );
            LendingTermOnboarding onboarder = LendingTermOnboarding(
                payable(addresses.mainnet(strings.LENDING_TERM_ONBOARDING))
            );
            LendingTermOffboarding offboarding = LendingTermOffboarding(
                payable(addresses.mainnet(strings.LENDING_TERM_OFFBOARDING))
            );
            VoltTimelockController timelock = VoltTimelockController(
                payable(addresses.mainnet(strings.TIMELOCK))
            );
            SurplusGuildMinter sgm = SurplusGuildMinter(
                addresses.mainnet(strings.SURPLUS_GUILD_MINTER)
            );
            ProfitManager mgr = ProfitManager(
                addresses.mainnet(strings.PROFIT_MANAGER)
            );
            RateLimitedMinter rateLimitedCreditMinter = RateLimitedMinter(
                addresses.mainnet(strings.RATE_LIMITED_CREDIT_MINTER)
            );
            RateLimitedMinter rateLimitedGuildMinter = RateLimitedMinter(
                addresses.mainnet(strings.RATE_LIMITED_GUILD_MINTER)
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

        /// PSM Verification
        {
            SimplePSM psm = SimplePSM(addresses.mainnet(strings.PSM_USDC));

            assertEq(psm.pegToken(), addresses.mainnet(strings.USDC));
            assertEq(psm.decimalCorrection(), 1e12);
            assertEq(psm.credit(), addresses.mainnet(strings.CREDIT_TOKEN));
            assertEq(
                psm.rlcm(),
                addresses.mainnet(strings.RATE_LIMITED_CREDIT_MINTER)
            );
            assertEq(
                psm.profitManager(),
                addresses.mainnet(strings.PROFIT_MANAGER)
            );
        }

        /// Rate Limited Minter Verification
        {
            RateLimitedMinter rateLimitedCreditMinter = RateLimitedMinter(
                addresses.mainnet(strings.RATE_LIMITED_CREDIT_MINTER)
            );
            assertEq(
                rateLimitedCreditMinter.token(),
                addresses.mainnet(strings.CREDIT_TOKEN)
            );
            assertEq(
                rateLimitedCreditMinter.role(),
                CoreRoles.RATE_LIMITED_CREDIT_MINTER
            );
        }
        {
            RateLimitedMinter rateLimitedGuildMinter = RateLimitedMinter(
                addresses.mainnet(strings.RATE_LIMITED_GUILD_MINTER)
            );
            assertEq(
                rateLimitedGuildMinter.token(),
                addresses.mainnet(strings.GUILD_TOKEN)
            );
            assertEq(
                rateLimitedGuildMinter.role(),
                CoreRoles.RATE_LIMITED_GUILD_MINTER
            );
        }

        /// GUILD and CREDIT Token Total Supply and balances
        {
            assertEq(
                ERC20MultiVotes(addresses.mainnet(strings.CREDIT_TOKEN))
                    .maxDelegates(),
                constants.MAX_DELEGATES
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet(strings.GUILD_TOKEN))
                    .maxDelegates(),
                constants.MAX_DELEGATES
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet(strings.GUILD_TOKEN))
                    .totalSupply(),
                constants.GUILD_SUPPLY
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet(strings.GUILD_TOKEN))
                    .balanceOf(addresses.mainnet(strings.TEAM_MULTISIG)),
                constants.GUILD_SUPPLY
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet(strings.CREDIT_TOKEN))
                    .totalSupply(),
                constants.CREDIT_SUPPLY
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet(strings.CREDIT_TOKEN))
                    .balanceOf(deployer),
                constants.CREDIT_SUPPLY
            );
        }
        /// PROFIT MANAGER Verification
        {
            assertEq(
                ProfitManager(addresses.mainnet(strings.PROFIT_MANAGER))
                    .credit(),
                addresses.mainnet(strings.CREDIT_TOKEN)
            );
            assertEq(
                ProfitManager(addresses.mainnet(strings.PROFIT_MANAGER))
                    .guild(),
                addresses.mainnet(strings.GUILD_TOKEN)
            );
            assertEq(
                ProfitManager(addresses.mainnet(strings.PROFIT_MANAGER))
                    .surplusBuffer(),
                0
            );

            (
                uint256 surplusBufferSplit,
                uint256 creditSplit,
                uint256 guildSplit,
                uint256 otherSplit,
                address otherRecipient
            ) = ProfitManager(addresses.mainnet(strings.PROFIT_MANAGER))
                    .getProfitSharingConfig();

            assertEq(surplusBufferSplit, constants.SURPLUS_BUFFER_SPLIT);
            assertEq(surplusBufferSplit, constants.SURPLUS_BUFFER_SPLIT);
            assertEq(surplusBufferSplit, constants.SURPLUS_BUFFER_SPLIT);
        }
    }
}
