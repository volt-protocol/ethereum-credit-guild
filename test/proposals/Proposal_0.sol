//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "@forge-std/Test.sol";

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
import {NameLib as strings} from "@test/utils/NameLib.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {VoltTimelockController} from "@src/governance/VoltTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";

/// @notice deployer must have 100 USDC to deploy the system on mainnet for the initial PSM mint.
contract Proposal_0 is Proposal {
    string public constant name = "Proposal_0";

    /// --------------------------------------------------------------
    /// --------------------------------------------------------------
    /// -------------------- DEPLOYMENT CONSTANTS --------------------
    /// --------------------------------------------------------------
    /// --------------------------------------------------------------

    /// @notice maximum guild supply is 1b tokens, however this number can change
    /// later if new tokens are minted
    uint256 internal constant GUILD_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice initial credit supply is 100 tokens after USDC PSM mint
    uint256 internal constant CREDIT_SUPPLY = 100 * 1e18;

    /// @notice initial amount of USDC to mint with is 100
    uint256 internal constant INITIAL_USDC_MINT_AMOUNT = 100 * 1e6;

    /// @notice maximum delegates for both credit and guild token
    uint256 internal constant MAX_DELEGATES = 12;

    /// @notice for each SDAI collateral, up to 1 credit can be borrowed
    uint256 internal constant MAX_SDAI_CREDIT_RATIO = 1e18;

    /// @notice credit hardcap at launch
    uint256 internal constant CREDIT_HARDCAP = 2_000_000 * 1e18;

    /// @notice SDAI credit hardcap at launch
    uint256 internal constant SDAI_CREDIT_HARDCAP = 2_000_000 * 1e18;

    /// ------------------------------------------------------------------------
    /// @notice Interest Rate Parameters
    /// ------------------------------------------------------------------------

    /// @notice rate to borrow against SDAI collateral
    uint256 internal constant SDAI_RATE = 0.04e18;

    /// ------------------------------------------------------------------------
    /// @notice Governance Parameters
    /// ------------------------------------------------------------------------

    /// @notice voting period in the DAO
    uint256 internal constant VOTING_PERIOD = 7000 * 3;

    /// @notice timelock delay for all governance actions
    uint256 internal constant TIMELOCK_DELAY = 3 days;

    /// @notice voting delay for the DAO
    uint256 internal constant VOTING_DELAY = 0;

    /// @notice proposal threshold for proposing governance actions to the DAO
    uint256 internal constant PROPOSAL_THRESHOLD = 2_500_000 * 1e18;

    /// @notice initial quorum for a proposal to pass on the DAO
    uint256 internal constant INITIAL_QUORUM = 10_000_000 * 1e18;

    /// @notice initial quorum for a proposal to be vetoed on the Veto DAO is 500k CREDIT
    uint256 internal constant INITIAL_QUORUM_VETO_DAO = 500_000 * 1e18;

    /// @notice initial quorum for a proposal to be offboarded on the Offboarding contract is 5m GUILD
    uint256 internal constant LENDING_TERM_OFFBOARDING_QUORUM =
        5_000_000 * 1e18;

    /// ------------------------------------------------------------------------
    /// @notice profit sharing configuration parameters for the Profit Manager
    /// ------------------------------------------------------------------------

    /// @notice 10% of profits go to the surplus buffer
    uint256 internal constant SURPLUS_BUFFER_SPLIT = 0.1e18;

    /// @notice 90% of profits go to credit holders that opt into rebasing
    uint256 internal constant CREDIT_SPLIT = 0.9e18;

    /// @notice 0% of profits go to guild holders staked in gauges
    uint256 internal constant GUILD_SPLIT = 0;

    /// @notice 0% of profits go to other
    uint256 internal constant OTHER_SPLIT = 0;

    function deploy(Addresses addresses) public {
        // Core
        {
            Core core = new Core();
            addresses.addMainnet("CORE", address(core));
        }

        // ProfitManager
        {
            ProfitManager profitManager = new ProfitManager(
                addresses.mainnet("CORE")
            );
            addresses.addMainnet(
                "PROFIT_MANAGER",
                address(profitManager)
            );
        }

        // Tokens & minting
        {
            CreditToken credit = new CreditToken(
                addresses.mainnet("CORE")
            );
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
                address(guild),
                CoreRoles.RATE_LIMITED_GUILD_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                uint128(GUILD_SUPPLY) // 1b
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

            addresses.addMainnet("CREDIT_TOKEN", address(credit));
            addresses.addMainnet("GUILD_TOKEN", address(guild));
            addresses.addMainnet(
                "RATE_LIMITED_CREDIT_MINTER",
                address(rateLimitedCreditMinter)
            );
            addresses.addMainnet(
                "RATE_LIMITED_GUILD_MINTER",
                address(rateLimitedGuildMinter)
            );
            addresses.addMainnet(
                "SURPLUS_GUILD_MINTER",
                address(guildMinter)
            );
        }

        // Auction House & LendingTerm Implementation V1
        {
            AuctionHouse auctionHouse = new AuctionHouse(
                addresses.mainnet("CORE"),
                650, // midPoint = 10m50s
                1800 // auctionDuration = 30m
            );

            LendingTerm termV1 = new LendingTerm();

            addresses.addMainnet("AUCTION_HOUSE", address(auctionHouse));
            addresses.addMainnet("LENDING_TERM", address(termV1));
        }

        // Governance
        {
            VoltTimelockController timelock = new VoltTimelockController(
                addresses.mainnet("CORE"),
                TIMELOCK_DELAY
            );
            VoltGovernor governor = new VoltGovernor(
                addresses.mainnet("CORE"),
                address(timelock),
                addresses.mainnet("GUILD_TOKEN"),
                VOTING_DELAY,
                VOTING_PERIOD,
                PROPOSAL_THRESHOLD,
                INITIAL_QUORUM
            );

            VoltVetoGovernor vetoGovernor = new VoltVetoGovernor(
                addresses.mainnet("CORE"),
                address(timelock),
                addresses.mainnet("CREDIT_TOKEN"),
                INITIAL_QUORUM_VETO_DAO // initialQuorum
            );
            LendingTermOffboarding termOffboarding = new LendingTermOffboarding(
                addresses.mainnet("CORE"),
                addresses.mainnet("GUILD_TOKEN"),
                LENDING_TERM_OFFBOARDING_QUORUM
            );
            LendingTermOnboarding termOnboarding = new LendingTermOnboarding(
                addresses.mainnet("LENDING_TERM"), // _lendingTermImplementation
                LendingTerm.LendingTermReferences({
                    profitManager: addresses.mainnet("PROFIT_MANAGER"),
                    guildToken: addresses.mainnet("GUILD_TOKEN"),
                    auctionHouse: addresses.mainnet("AUCTION_HOUSE"),
                    creditMinter: addresses.mainnet(
                        "RATE_LIMITED_CREDIT_MINTER"
                    ),
                    creditToken: addresses.mainnet("CREDIT_TOKEN")
                }), /// _lendingTermReferences
                1, // _gaugeType
                addresses.mainnet("CORE"), // _core
                address(timelock), // _timelock
                VOTING_DELAY, // initialVotingDelay
                VOTING_PERIOD, // initialVotingPeriod (~7000 blocks/day)
                PROPOSAL_THRESHOLD, // initialProposalThreshold
                INITIAL_QUORUM // initialQuorum
            );

            addresses.addMainnet("TIMELOCK", address(timelock));
            addresses.addMainnet("GOVERNOR", address(governor));
            addresses.addMainnet("VETO_GOVERNOR", address(vetoGovernor));
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
                addresses.mainnet("CORE"),
                addresses.mainnet("PROFIT_MANAGER"),
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"),
                addresses.mainnet("CREDIT_TOKEN"),
                addresses.mainnet("ERC20_USDC")
            );

            LendingTermOnboarding termOnboarding = LendingTermOnboarding(
                payable(addresses.mainnet("LENDING_TERM_ONBOARDING"))
            );

            address termSDAI1 = termOnboarding.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet("ERC20_SDAI"),
                    maxDebtPerCollateralToken: MAX_SDAI_CREDIT_RATIO, // 1 CREDIT per SDAI collateral + no decimals correction
                    interestRate: SDAI_RATE, // 3%
                    maxDelayBetweenPartialRepay: 0, // no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    hardCap: CREDIT_HARDCAP // max 20k CREDIT issued
                })
            );

            addresses.addMainnet("PSM_USDC", address(psm));
            addresses.addMainnet("TERM_SDAI_1", termSDAI1);
        }
    }

    function afterDeploy(Addresses addresses, address deployer) public {
        Core core = Core(addresses.mainnet("CORE"));

        // grant roles to smart contracts
        // GOVERNOR
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet("TIMELOCK"));
        core.grantRole(
            CoreRoles.GOVERNOR,
            addresses.mainnet("LENDING_TERM_OFFBOARDING")
        );

        // GUARDIAN
        core.grantRole(
            CoreRoles.GUARDIAN,
            addresses.mainnet("TEAM_MULTISIG")
        );

        // CREDIT_MINTER
        core.grantRole(
            CoreRoles.CREDIT_MINTER,
            addresses.mainnet("RATE_LIMITED_CREDIT_MINTER")
        );

        // RATE_LIMITED_CREDIT_MINTER
        core.grantRole(
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            addresses.mainnet("PSM_USDC")
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
            addresses.mainnet("SURPLUS_GUILD_MINTER")
        );

        // RATE_LIMITED_GUILD_MINTER
        core.grantRole(CoreRoles.GUILD_MINTER, deployer);

        /// Grant Multisig Guild Rate Limited Minter
        core.grantRole(
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            addresses.mainnet("TEAM_MULTISIG")
        );

        // GAUGE_ADD
        core.grantRole(
            CoreRoles.GAUGE_ADD,
            addresses.mainnet("TIMELOCK")
        );
        core.grantRole(CoreRoles.GAUGE_ADD, deployer);

        // GAUGE_REMOVE
        core.grantRole(
            CoreRoles.GAUGE_REMOVE,
            addresses.mainnet("TIMELOCK")
        );
        core.grantRole(
            CoreRoles.GAUGE_REMOVE,
            addresses.mainnet("LENDING_TERM_OFFBOARDING")
        );

        // GAUGE_PARAMETERS
        core.grantRole(
            CoreRoles.GAUGE_PARAMETERS,
            addresses.mainnet("TIMELOCK")
        );
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, deployer);

        // GAUGE_PNL_NOTIFIER
        core.grantRole(
            CoreRoles.GAUGE_PNL_NOTIFIER,
            addresses.mainnet("TERM_SDAI_1")
        );

        // GUILD_GOVERNANCE_PARAMETERS
        core.grantRole(
            CoreRoles.GUILD_GOVERNANCE_PARAMETERS,
            addresses.mainnet("TIMELOCK")
        );
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);

        // GUILD_SURPLUS_BUFFER_WITHDRAW
        core.grantRole(
            CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW,
            addresses.mainnet("SURPLUS_GUILD_MINTER")
        );

        // CREDIT_GOVERNANCE_PARAMETERS
        core.grantRole(
            CoreRoles.CREDIT_GOVERNANCE_PARAMETERS,
            addresses.mainnet("TIMELOCK")
        );
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);

        // CREDIT_REBASE_PARAMETERS
        core.grantRole(
            CoreRoles.CREDIT_REBASE_PARAMETERS,
            addresses.mainnet("TIMELOCK")
        );

        // TIMELOCK_PROPOSER
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            addresses.mainnet("GOVERNOR")
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
            addresses.mainnet("VETO_GOVERNOR")
        );
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            addresses.mainnet("TEAM_MULTISIG")
        );

        // Configuration
        ProfitManager(addresses.mainnet("PROFIT_MANAGER"))
            .initializeReferences(
                addresses.mainnet("CREDIT_TOKEN"),
                addresses.mainnet("GUILD_TOKEN")
            );
        ProfitManager(addresses.mainnet("PROFIT_MANAGER"))
            .setProfitSharingConfig(
                SURPLUS_BUFFER_SPLIT, // 10% surplusBufferSplit
                CREDIT_SPLIT, // 90% creditSplit
                GUILD_SPLIT, // guildSplit
                OTHER_SPLIT, // otherSplit
                address(0) // otherRecipient
            );
        GuildToken(addresses.mainnet("GUILD_TOKEN"))
            .setCanExceedMaxGauges(
                addresses.mainnet("SURPLUS_GUILD_MINTER"),
                true
            );
        GuildToken(addresses.mainnet("GUILD_TOKEN")).setMaxGauges(10);
        GuildToken(addresses.mainnet("GUILD_TOKEN")).addGauge(
            1,
            addresses.mainnet("TERM_SDAI_1")
        );
        GuildToken(addresses.mainnet("GUILD_TOKEN")).setMaxDelegates(
            MAX_DELEGATES
        );
        CreditToken(addresses.mainnet("CREDIT_TOKEN")).setMaxDelegates(
            MAX_DELEGATES
        );

        // Mint the first CREDIT tokens and enter rebase
        // Doing this with a non-dust balance ensures the share price internally
        // to the CreditToken has a reasonable size.
        {
            ERC20 usdc = ERC20(addresses.mainnet("ERC20_USDC"));
            SimplePSM psm = SimplePSM(addresses.mainnet("PSM_USDC"));
            CreditToken credit = CreditToken(
                addresses.mainnet("CREDIT_TOKEN")
            );

            if (usdc.balanceOf(deployer) < INITIAL_USDC_MINT_AMOUNT) {
                deal(
                    address(usdc),
                    deployer,
                    INITIAL_USDC_MINT_AMOUNT
                );
            }

            usdc.approve(address(psm), INITIAL_USDC_MINT_AMOUNT);
            psm.mint(deployer, INITIAL_USDC_MINT_AMOUNT);
            credit.enterRebase();
        }

        // deployer renounces governor role
        core.renounceRole(CoreRoles.GOVERNOR, deployer);
        core.renounceRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GAUGE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GAUGE_ADD, deployer);
        /// deployer renounces guild minter role used to create supply
        core.renounceRole(CoreRoles.GUILD_MINTER, deployer);
    }

    function run(Addresses addresses, address deployer) public pure {}

    function teardown(Addresses addresses, address deployer) public pure {}

    function validate(Addresses addresses, address deployer) public {
        /// CORE Verification
        Core core = Core(addresses.mainnet("CORE"));
        {
            assertEq(
                address(core),
                address(SimplePSM(addresses.mainnet("PSM_USDC")).core())
            );
            assertEq(
                address(core),
                address(
                    LendingTerm(addresses.mainnet("TERM_SDAI_1")).core()
                )
            );

            CreditToken credit = CreditToken(
                addresses.mainnet("CREDIT_TOKEN")
            );
            GuildToken guild = GuildToken(
                addresses.mainnet("GUILD_TOKEN")
            );
            LendingTermOnboarding onboarder = LendingTermOnboarding(
                payable(addresses.mainnet("LENDING_TERM_ONBOARDING"))
            );
            LendingTermOffboarding offboarding = LendingTermOffboarding(
                payable(addresses.mainnet("LENDING_TERM_OFFBOARDING"))
            );
            VoltTimelockController timelock = VoltTimelockController(
                payable(addresses.mainnet("TIMELOCK"))
            );
            SurplusGuildMinter sgm = SurplusGuildMinter(
                addresses.mainnet("SURPLUS_GUILD_MINTER")
            );
            ProfitManager mgr = ProfitManager(
                addresses.mainnet("PROFIT_MANAGER")
            );
            RateLimitedMinter rateLimitedCreditMinter = RateLimitedMinter(
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER")
            );
            RateLimitedMinter rateLimitedGuildMinter = RateLimitedMinter(
                addresses.mainnet("RATE_LIMITED_GUILD_MINTER")
            );
            AuctionHouse auctionHouse = AuctionHouse(
                addresses.mainnet("AUCTION_HOUSE")
            );
            VoltGovernor governor = VoltGovernor(
                payable(addresses.mainnet("GOVERNOR"))
            );
            VoltVetoGovernor vetoGovernor = VoltVetoGovernor(
                payable(addresses.mainnet("VETO_GOVERNOR"))
            );

            assertEq(address(core), address(mgr.core()));
            assertEq(address(core), address(sgm.core()));
            assertEq(address(core), address(guild.core()));
            assertEq(address(core), address(credit.core()));
            assertEq(address(core), address(timelock.core()));
            assertEq(address(core), address(governor.core()));
            assertEq(address(core), address(onboarder.core()));
            assertEq(address(core), address(offboarding.core()));
            assertEq(address(core), address(auctionHouse.core()));
            assertEq(address(core), address(vetoGovernor.core()));
            assertEq(address(core), address(rateLimitedGuildMinter.core()));
            assertEq(address(core), address(rateLimitedCreditMinter.core()));
        }

        /// PSM Verification
        {
            SimplePSM psm = SimplePSM(addresses.mainnet("PSM_USDC"));

            assertEq(psm.pegToken(), addresses.mainnet("ERC20_USDC"));
            assertEq(psm.decimalCorrection(), 1e12);
            assertEq(psm.credit(), addresses.mainnet("CREDIT_TOKEN"));
            assertEq(
                psm.rlcm(),
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER")
            );
            assertEq(
                psm.profitManager(),
                addresses.mainnet("PROFIT_MANAGER")
            );
        }

        /// Rate Limited Minter Verification
        {
            RateLimitedMinter rateLimitedCreditMinter = RateLimitedMinter(
                addresses.mainnet("RATE_LIMITED_CREDIT_MINTER")
            );
            assertEq(
                rateLimitedCreditMinter.token(),
                addresses.mainnet("CREDIT_TOKEN")
            );
            assertEq(
                rateLimitedCreditMinter.role(),
                CoreRoles.RATE_LIMITED_CREDIT_MINTER
            );
            assertEq(
                rateLimitedCreditMinter.rateLimitPerSecond(),
                0,
                "rate limit per second credit incorrect"
            );
            assertEq(
                CREDIT_HARDCAP,
                rateLimitedCreditMinter.bufferCap(),
                "credit buffercap incorrect"
            );
            assertEq(
                rateLimitedCreditMinter.buffer(),
                rateLimitedCreditMinter.bufferCap() - CREDIT_SUPPLY,
                "credit buffer incorrect"
            );
        }
        {
            RateLimitedMinter rateLimitedGuildMinter = RateLimitedMinter(
                addresses.mainnet("RATE_LIMITED_GUILD_MINTER")
            );
            assertEq(
                rateLimitedGuildMinter.token(),
                addresses.mainnet("GUILD_TOKEN")
            );
            assertEq(
                rateLimitedGuildMinter.role(),
                CoreRoles.RATE_LIMITED_GUILD_MINTER
            );
            assertEq(
                rateLimitedGuildMinter.rateLimitPerSecond(),
                0,
                "rate limit per second guild incorrect"
            );
            assertEq(
                rateLimitedGuildMinter.bufferCap(),
                GUILD_SUPPLY,
                "guild buffercap incorrect"
            );
            assertEq(
                rateLimitedGuildMinter.buffer(),
                GUILD_SUPPLY,
                "guild buffer incorrect"
            );
        }

        /// GUILD and CREDIT Token Total Supply and balances
        {
            assertEq(
                ERC20MultiVotes(addresses.mainnet("CREDIT_TOKEN"))
                    .maxDelegates(),
                MAX_DELEGATES
            );
            /// guild token starts non-transferrable
            assertFalse(
                GuildToken(addresses.mainnet("GUILD_TOKEN"))
                    .transferable()
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet("GUILD_TOKEN"))
                    .maxDelegates(),
                MAX_DELEGATES
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet("GUILD_TOKEN"))
                    .totalSupply(),
                0
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet("GUILD_TOKEN"))
                    .balanceOf(addresses.mainnet("TEAM_MULTISIG")),
                0
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet("CREDIT_TOKEN"))
                    .totalSupply(),
                CREDIT_SUPPLY
            );
            assertEq(
                ERC20MultiVotes(addresses.mainnet("CREDIT_TOKEN"))
                    .balanceOf(deployer),
                CREDIT_SUPPLY
            );
        }
        /// PROFIT MANAGER Verification
        {
            assertEq(
                ProfitManager(addresses.mainnet("PROFIT_MANAGER"))
                    .credit(),
                addresses.mainnet("CREDIT_TOKEN")
            );
            assertEq(
                ProfitManager(addresses.mainnet("PROFIT_MANAGER"))
                    .guild(),
                addresses.mainnet("GUILD_TOKEN")
            );
            assertEq(
                ProfitManager(addresses.mainnet("PROFIT_MANAGER"))
                    .surplusBuffer(),
                0
            );

            (
                uint256 surplusBufferSplit,
                uint256 creditSplit,
                uint256 guildSplit,
                uint256 otherSplit,
                address otherRecipient
            ) = ProfitManager(addresses.mainnet("PROFIT_MANAGER"))
                    .getProfitSharingConfig();

            assertEq(surplusBufferSplit, SURPLUS_BUFFER_SPLIT);
            assertEq(creditSplit, CREDIT_SPLIT);
            assertEq(guildSplit, GUILD_SPLIT);
            assertEq(otherSplit, OTHER_SPLIT);
            assertEq(otherRecipient, address(0));
        }
        /// TIMELOCK Verification
        {
            VoltTimelockController timelock = VoltTimelockController(
                payable(addresses.mainnet("TIMELOCK"))
            );

            assertEq(timelock.getMinDelay(), TIMELOCK_DELAY);
        }
        /// Auction House Verification
        {
            AuctionHouse auctionHouse = AuctionHouse(
                addresses.mainnet("AUCTION_HOUSE")
            );

            assertEq(auctionHouse.midPoint(), 650);
            assertEq(auctionHouse.auctionDuration(), 30 minutes);
            assertEq(auctionHouse.nAuctionsInProgress(), 0);
        }

        {
            ProfitManager profitManager = ProfitManager(
                addresses.mainnet("PROFIT_MANAGER")
            );
            assertEq(
                profitManager.surplusBuffer(),
                0,
                "starting surplus not 0"
            );
            assertEq(
                profitManager.credit(),
                addresses.mainnet("CREDIT_TOKEN"),
                "credit address incorrect"
            );
            assertEq(
                profitManager.guild(),
                addresses.mainnet("GUILD_TOKEN"),
                "guild address incorrect"
            );
            assertEq(
                profitManager.creditMultiplier(),
                1e18,
                "credit multiplier incorrect"
            );

            (
                uint256 surplusBufferSplit,
                uint256 creditSplit,
                uint256 guildSplit,
                uint256 otherSplit,
                address otherRecipient
            ) = profitManager.getProfitSharingConfig();
            assertEq(
                surplusBufferSplit,
                0.1e18,
                "incorrect surplus buffer split"
            );
            assertEq(creditSplit, 0.9e18, "incorrect credit split");
            assertEq(guildSplit, 0, "incorrect guild split");
            assertEq(otherSplit, 0, "incorrect other split");
            assertEq(otherRecipient, address(0));
        }

        /// Governor Verification
        {
            VoltGovernor governor = VoltGovernor(
                payable(addresses.mainnet("GOVERNOR"))
            );
            VoltVetoGovernor vetoGovernor = VoltVetoGovernor(
                payable(addresses.mainnet("VETO_GOVERNOR"))
            );

            assertEq(
                governor.quorum(0),
                INITIAL_QUORUM,
                "governor quorum"
            );
            assertEq(
                governor.votingDelay(),
                VOTING_DELAY,
                "governor voting delay"
            );
            assertEq(
                governor.votingPeriod(),
                VOTING_PERIOD,
                "governor voting period"
            );
            assertEq(
                governor.proposalThreshold(),
                PROPOSAL_THRESHOLD,
                "proposal threshold"
            );
            assertEq(
                vetoGovernor.quorum(0),
                INITIAL_QUORUM_VETO_DAO,
                "veto governor quorum"
            );
            assertEq(
                vetoGovernor.votingDelay(),
                VOTING_DELAY,
                "veto governor voting delay"
            );
            assertEq(
                vetoGovernor.votingPeriod(),
                2425847,
                "veto governor voting period"
            );
        }
    }
}
