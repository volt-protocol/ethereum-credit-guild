//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Core} from "@src/core/Core.sol";
import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {AddressLib} from "@test/proposals/AddressLib.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {GuildVetoGovernor} from "@src/governance/GuildVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";

/// @notice deployer must have 100 USDC to deploy the system on mainnet for the initial PSM mint.
contract GIP_0 is Proposal {
    string public constant name = "Proposal_0";

    /// --------------------------------------------------------------
    /// --------------------------------------------------------------
    /// -------------------- DEPLOYMENT CONSTANTS --------------------
    /// --------------------------------------------------------------
    /// --------------------------------------------------------------

    /// @notice maximum guild supply is 1b tokens, however this number can change
    /// later if new tokens are minted
    uint256 internal constant GUILD_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice guild mint ratio is 5e18, meaning for 1 credit 5 guild tokens are
    /// minted in SurplusGuildMinter
    uint256 internal constant GUILD_MINT_RATIO = 5e18;

    /// @notice ratio of guild tokens received per Credit earned in
    /// the Surplus Guild Minter
    uint256 internal constant GUILD_CREDIT_REWARD_RATIO = 0.1e18;

    /// @notice maximum delegates for both credit and guild token
    uint256 internal constant MAX_DELEGATES = 10;

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
    /// @notice profit sharing configuration parameters for the Profit Manager
    /// ------------------------------------------------------------------------

    /// @notice 9% of profits go to the surplus buffer
    uint256 internal constant SURPLUS_BUFFER_SPLIT = 0.09e18;

    /// @notice 90% of profits go to credit holders that opt into rebasing
    uint256 internal constant CREDIT_SPLIT = 0.9e18;

    /// @notice 1% of profits go to guild holders staked in gauges
    uint256 internal constant GUILD_SPLIT = 0.01e18;

    /// @notice 0% of profits go to other
    uint256 internal constant OTHER_SPLIT = 0;
    address internal constant OTHER_ADDRESS = address(0);

    uint256 public constant BLOCKS_PER_DAY = 7164;

    // governance params
    uint256 public constant DAO_TIMELOCK_DELAY = 7 days;
    uint256 public constant ONBOARD_TIMELOCK_DELAY = 1 days;
    uint256 public constant DAO_GOVERNOR_GUILD_VOTING_DELAY =
        0 * BLOCKS_PER_DAY;
    uint256 public constant DAO_GOVERNOR_GUILD_VOTING_PERIOD =
        3 * BLOCKS_PER_DAY;
    uint256 public constant DAO_GOVERNOR_GUILD_PROPOSAL_THRESHOLD =
        2_500_000e18;
    uint256 public constant DAO_GOVERNOR_GUILD_QUORUM = 25_000_000e18;
    uint256 public constant DAO_VETO_CREDIT_QUORUM = 5_000_000e18;
    uint256 public constant DAO_VETO_GUILD_QUORUM = 15_000_000e18;
    uint256 public constant ONBOARD_GOVERNOR_GUILD_VOTING_DELAY =
        0 * BLOCKS_PER_DAY;
    uint256 public constant ONBOARD_GOVERNOR_GUILD_VOTING_PERIOD =
        2 * BLOCKS_PER_DAY;
    uint256 public constant ONBOARD_GOVERNOR_GUILD_PROPOSAL_THRESHOLD =
        1_000_000e18;
    uint256 public constant ONBOARD_GOVERNOR_GUILD_QUORUM = 10_000_000e18;
    uint256 public constant ONBOARD_VETO_CREDIT_QUORUM = 5_000_000e18;
    uint256 public constant ONBOARD_VETO_GUILD_QUORUM = 10_000_000e18;
    uint256 public constant OFFBOARD_QUORUM = 10_000_000e18;

    function deploy() public {
        // Core
        {
            Core core = new Core();
            AddressLib.set("CORE", address(core));
        }

        // ProfitManager
        {
            ProfitManager profitManager = new ProfitManager(
                AddressLib.get("CORE")
            );
            AddressLib.set("PROFIT_MANAGER", address(profitManager));
        }

        // Tokens & minting
        {
            CreditToken credit = new CreditToken(
                AddressLib.get("CORE"),
                "Ethereum Credit Guild - gUSDC",
                "gUSDC"
            );
            GuildToken guild = new GuildToken(
                AddressLib.get("CORE"),
                AddressLib.get("PROFIT_MANAGER")
            );
            RateLimitedMinter rateLimitedCreditMinter = new RateLimitedMinter(
                AddressLib.get("CORE"),
                address(credit),
                CoreRoles.RATE_LIMITED_CREDIT_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                uint128(CREDIT_HARDCAP) // bufferCap
            );
            RateLimitedMinter rateLimitedGuildMinter = new RateLimitedMinter(
                AddressLib.get("CORE"),
                address(guild),
                CoreRoles.RATE_LIMITED_GUILD_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                uint128(GUILD_SUPPLY) // 1b
            );
            SurplusGuildMinter guildMinter = new SurplusGuildMinter(
                AddressLib.get("CORE"),
                AddressLib.get("PROFIT_MANAGER"),
                address(credit),
                address(guild),
                address(rateLimitedGuildMinter),
                GUILD_MINT_RATIO, // ratio of GUILD minted per CREDIT staked
                GUILD_CREDIT_REWARD_RATIO // amount of GUILD received per CREDIT earned from staking in Gauges
            );

            AddressLib.set("ERC20_GUSDC", address(credit));
            AddressLib.set("ERC20_GUILD", address(guild));
            AddressLib.set(
                "RATE_LIMITED_CREDIT_MINTER",
                address(rateLimitedCreditMinter)
            );
            AddressLib.set(
                "RATE_LIMITED_GUILD_MINTER",
                address(rateLimitedGuildMinter)
            );
            AddressLib.set("SURPLUS_GUILD_MINTER", address(guildMinter));
        }

        // Auction House & LendingTerm Implementation V1 & PSM
        {
            AuctionHouse auctionHouse = new AuctionHouse(
                AddressLib.get("CORE"),
                650, // midPoint = 10m50s
                1800 // auctionDuration = 30m
            );

            LendingTerm termV1 = new LendingTerm();

            SimplePSM psm = new SimplePSM(
                AddressLib.get("CORE"),
                AddressLib.get("PROFIT_MANAGER"),
                AddressLib.get("ERC20_GUSDC"),
                AddressLib.get("ERC20_USDC")
            );

            AddressLib.set("AUCTION_HOUSE", address(auctionHouse));
            AddressLib.set("LENDING_TERM_V1", address(termV1));
            AddressLib.set("PSM_USDC", address(psm));
        }

        // Governance
        {
            GuildTimelockController daoTimelock = new GuildTimelockController(
                AddressLib.get("CORE"),
                DAO_TIMELOCK_DELAY
            );
            GuildGovernor daoGovernorGuild = new GuildGovernor(
                AddressLib.get("CORE"),
                address(daoTimelock),
                AddressLib.get("ERC20_GUILD"),
                DAO_GOVERNOR_GUILD_VOTING_DELAY, // initialVotingDelay
                DAO_GOVERNOR_GUILD_VOTING_PERIOD, // initialVotingPeriod
                DAO_GOVERNOR_GUILD_PROPOSAL_THRESHOLD, // initialProposalThreshold
                DAO_GOVERNOR_GUILD_QUORUM // initialQuorum
            );
            GuildVetoGovernor daoVetoCredit = new GuildVetoGovernor(
                AddressLib.get("CORE"),
                address(daoTimelock),
                AddressLib.get("ERC20_GUSDC"),
                DAO_VETO_CREDIT_QUORUM // initialQuorum
            );
            GuildVetoGovernor daoVetoGuild = new GuildVetoGovernor(
                AddressLib.get("CORE"),
                address(daoTimelock),
                AddressLib.get("ERC20_GUILD"),
                DAO_VETO_GUILD_QUORUM // initialQuorum
            );

            GuildTimelockController onboardTimelock = new GuildTimelockController(
                AddressLib.get("CORE"),
                ONBOARD_TIMELOCK_DELAY
            );
            LendingTermOnboarding onboardGovernorGuild = new LendingTermOnboarding(
                    LendingTerm.LendingTermReferences({
                        profitManager: AddressLib.get("PROFIT_MANAGER"),
                        guildToken: AddressLib.get("ERC20_GUILD"),
                        auctionHouse: AddressLib.get("AUCTION_HOUSE"),
                        creditMinter: AddressLib.get(
                            "RATE_LIMITED_CREDIT_MINTER"
                        ),
                        creditToken: AddressLib.get("ERC20_GUSDC")
                    }), /// _lendingTermReferences
                    1, // _gaugeType
                    AddressLib.get("CORE"), // _core
                    address(onboardTimelock), // _timelock
                    ONBOARD_GOVERNOR_GUILD_VOTING_DELAY, // initialVotingDelay
                    ONBOARD_GOVERNOR_GUILD_VOTING_PERIOD, // initialVotingPeriod
                    ONBOARD_GOVERNOR_GUILD_PROPOSAL_THRESHOLD, // initialProposalThreshold
                    ONBOARD_GOVERNOR_GUILD_QUORUM // initialQuorum
                );
            GuildVetoGovernor onboardVetoCredit = new GuildVetoGovernor(
                AddressLib.get("CORE"),
                address(onboardTimelock),
                AddressLib.get("ERC20_GUSDC"),
                ONBOARD_VETO_CREDIT_QUORUM // initialQuorum
            );
            GuildVetoGovernor onboardVetoGuild = new GuildVetoGovernor(
                AddressLib.get("CORE"),
                address(onboardTimelock),
                AddressLib.get("ERC20_GUILD"),
                ONBOARD_VETO_GUILD_QUORUM // initialQuorum
            );

            LendingTermOffboarding termOffboarding = new LendingTermOffboarding(
                AddressLib.get("CORE"),
                AddressLib.get("ERC20_GUILD"),
                AddressLib.get("PSM_USDC"),
                OFFBOARD_QUORUM // quorum
            );

            AddressLib.set(
                "DAO_GOVERNOR_GUILD",
                address(daoGovernorGuild)
            );
            AddressLib.set("DAO_TIMELOCK", address(daoTimelock));
            AddressLib.set("DAO_VETO_CREDIT", address(daoVetoCredit));
            AddressLib.set("DAO_VETO_GUILD", address(daoVetoGuild));
            AddressLib.set(
                "ONBOARD_GOVERNOR_GUILD",
                address(onboardGovernorGuild)
            );
            AddressLib.set("ONBOARD_TIMELOCK", address(onboardTimelock));
            AddressLib.set(
                "ONBOARD_VETO_CREDIT",
                address(onboardVetoCredit)
            );
            AddressLib.set(
                "ONBOARD_VETO_GUILD",
                address(onboardVetoGuild)
            );
            AddressLib.set(
                "OFFBOARD_GOVERNOR_GUILD",
                address(termOffboarding)
            );
        }

        // Terms
        {
            LendingTermOnboarding termOnboarding = LendingTermOnboarding(
                payable(AddressLib.get("ONBOARD_GOVERNOR_GUILD"))
            );
            address _lendingTermV1 = AddressLib.get("LENDING_TERM_V1");
            termOnboarding.allowImplementation(_lendingTermV1, true);

            address termSDAI1 = termOnboarding.createTerm(
                _lendingTermV1,
                LendingTerm.LendingTermParams({
                    collateralToken: AddressLib.get("ERC20_SDAI"),
                    maxDebtPerCollateralToken: 1e18, // 1 CREDIT per SDAI collateral + no decimals correction
                    interestRate: SDAI_RATE, // 4%
                    maxDelayBetweenPartialRepay: 0, // no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    hardCap: CREDIT_HARDCAP // max 2m CREDIT issued
                })
            );

            AddressLib.set("TERM_SDAI_1", termSDAI1);
        }
    }

    function afterDeploy(address deployer) public {
        Core core = Core(AddressLib.get("CORE"));

        // grant roles to smart contracts
        // GOVERNOR
        core.grantRole(CoreRoles.GOVERNOR, AddressLib.get("DAO_TIMELOCK"));
        core.grantRole(
            CoreRoles.GOVERNOR,
            AddressLib.get("ONBOARD_TIMELOCK")
        );
        core.grantRole(
            CoreRoles.GOVERNOR,
            AddressLib.get("OFFBOARD_GOVERNOR_GUILD")
        );

        // GUARDIAN
        core.grantRole(CoreRoles.GUARDIAN, AddressLib.get("TEAM_MULTISIG"));

        // CREDIT_MINTER
        core.grantRole(
            CoreRoles.CREDIT_MINTER,
            AddressLib.get("RATE_LIMITED_CREDIT_MINTER")
        );
        core.grantRole(CoreRoles.CREDIT_MINTER, AddressLib.get("PSM_USDC"));

        // RATE_LIMITED_CREDIT_MINTER
        core.grantRole(
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            AddressLib.get("TERM_SDAI_1")
        );

        // GUILD_MINTER
        core.grantRole(
            CoreRoles.GUILD_MINTER,
            AddressLib.get("RATE_LIMITED_GUILD_MINTER")
        );

        // RATE_LIMITED_GUILD_MINTER
        core.grantRole(
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            AddressLib.get("SURPLUS_GUILD_MINTER")
        );

        /// Grant Multisig Guild Rate Limited Minter
        core.grantRole(
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            AddressLib.get("TEAM_MULTISIG")
        );

        // GAUGE_ADD
        core.grantRole(CoreRoles.GAUGE_ADD, AddressLib.get("DAO_TIMELOCK"));
        core.grantRole(
            CoreRoles.GAUGE_ADD,
            AddressLib.get("ONBOARD_TIMELOCK")
        );
        core.grantRole(CoreRoles.GAUGE_ADD, deployer);

        // GAUGE_REMOVE
        core.grantRole(
            CoreRoles.GAUGE_REMOVE,
            AddressLib.get("DAO_TIMELOCK")
        );
        core.grantRole(
            CoreRoles.GAUGE_REMOVE,
            AddressLib.get("OFFBOARD_GOVERNOR_GUILD")
        );

        // GAUGE_PARAMETERS
        core.grantRole(
            CoreRoles.GAUGE_PARAMETERS,
            AddressLib.get("DAO_TIMELOCK")
        );
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, deployer);

        // GAUGE_PNL_NOTIFIER
        core.grantRole(
            CoreRoles.GAUGE_PNL_NOTIFIER,
            AddressLib.get("TERM_SDAI_1")
        );

        // GUILD_GOVERNANCE_PARAMETERS
        core.grantRole(
            CoreRoles.GUILD_GOVERNANCE_PARAMETERS,
            AddressLib.get("DAO_TIMELOCK")
        );
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);

        // GUILD_SURPLUS_BUFFER_WITHDRAW
        core.grantRole(
            CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW,
            AddressLib.get("SURPLUS_GUILD_MINTER")
        );

        // CREDIT_GOVERNANCE_PARAMETERS
        core.grantRole(
            CoreRoles.CREDIT_GOVERNANCE_PARAMETERS,
            AddressLib.get("DAO_TIMELOCK")
        );
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);

        // CREDIT_REBASE_PARAMETERS
        core.grantRole(
            CoreRoles.CREDIT_REBASE_PARAMETERS,
            AddressLib.get("DAO_TIMELOCK")
        );
        core.grantRole(
            CoreRoles.CREDIT_REBASE_PARAMETERS,
            AddressLib.get("PSM_USDC")
        );

        // TIMELOCK_PROPOSER
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            AddressLib.get("DAO_GOVERNOR_GUILD")
        );
        core.grantRole(
            CoreRoles.TIMELOCK_PROPOSER,
            AddressLib.get("ONBOARD_GOVERNOR_GUILD")
        );

        // TIMELOCK_EXECUTOR
        core.grantRole(CoreRoles.TIMELOCK_EXECUTOR, address(0)); // anyone can execute

        // TIMELOCK_CANCELLER

        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            AddressLib.get("DAO_VETO_CREDIT")
        );
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            AddressLib.get("DAO_VETO_GUILD")
        );
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            AddressLib.get("ONBOARD_VETO_CREDIT")
        );
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            AddressLib.get("ONBOARD_VETO_GUILD")
        );
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            AddressLib.get("DAO_GOVERNOR_GUILD")
        );
        core.grantRole(
            CoreRoles.TIMELOCK_CANCELLER,
            AddressLib.get("ONBOARD_GOVERNOR_GUILD")
        );

        // Configuration
        ProfitManager(AddressLib.get("PROFIT_MANAGER")).initializeReferences(
            AddressLib.get("ERC20_GUSDC"),
            AddressLib.get("ERC20_GUILD"),
            AddressLib.get("PSM_USDC")
        );
        ProfitManager(AddressLib.get("PROFIT_MANAGER"))
            .setProfitSharingConfig(
                SURPLUS_BUFFER_SPLIT, // 9% surplusBufferSplit
                CREDIT_SPLIT, // 90% creditSplit
                GUILD_SPLIT, // 1% guildSplit
                OTHER_SPLIT, // otherSplit
                OTHER_ADDRESS // otherRecipient
            );
        GuildToken(AddressLib.get("ERC20_GUILD")).setCanExceedMaxGauges(
            AddressLib.get("SURPLUS_GUILD_MINTER"),
            true
        );
        GuildToken(AddressLib.get("ERC20_GUILD")).setMaxGauges(10);
        GuildToken(AddressLib.get("ERC20_GUILD")).addGauge(
            1,
            AddressLib.get("TERM_SDAI_1")
        );
        GuildToken(AddressLib.get("ERC20_GUILD")).setMaxDelegates(
            MAX_DELEGATES
        );
        CreditToken(AddressLib.get("ERC20_GUSDC")).setMaxDelegates(
            MAX_DELEGATES
        );

        // deployer renounces governor role
        core.renounceRole(CoreRoles.GOVERNOR, deployer);
        core.renounceRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GAUGE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GAUGE_ADD, deployer);
    }

    function run(address deployer) public pure {}

    function teardown(address deployer) public pure {}

    function validate(address deployer) public {
        /// CORE Verification
        Core core = Core(AddressLib.get("CORE"));
        {
            assertEq(
                address(core),
                address(SimplePSM(AddressLib.get("PSM_USDC")).core()),
                "USDC PSM Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(LendingTerm(AddressLib.get("TERM_SDAI_1")).core()),
                "sDAI Term Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(
                    LendingTerm(AddressLib.get("ONBOARD_VETO_GUILD")).core()
                ),
                "ONBOARD_VETO_GUILD Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(
                    LendingTerm(AddressLib.get("OFFBOARD_GOVERNOR_GUILD"))
                        .core()
                ),
                "OFFBOARD_GOVERNOR_GUILD Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(
                    LendingTerm(AddressLib.get("ONBOARD_TIMELOCK")).core()
                ),
                "ONBOARD_TIMELOCK Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(
                    LendingTerm(AddressLib.get("ONBOARD_GOVERNOR_GUILD"))
                        .core()
                ),
                "ONBOARD_GOVERNOR_GUILD Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(
                    LendingTerm(AddressLib.get("DAO_VETO_GUILD")).core()
                ),
                "DAO_VETO_GUILD Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(
                    LendingTerm(AddressLib.get("DAO_VETO_CREDIT")).core()
                ),
                "DAO_VETO_CREDIT Incorrect Core Address"
            );

            CreditToken credit = CreditToken(AddressLib.get("ERC20_GUSDC"));
            GuildToken guild = GuildToken(AddressLib.get("ERC20_GUILD"));
            LendingTermOnboarding onboarder = LendingTermOnboarding(
                payable(AddressLib.get("ONBOARD_GOVERNOR_GUILD"))
            );
            LendingTermOffboarding offboarding = LendingTermOffboarding(
                payable(AddressLib.get("OFFBOARD_GOVERNOR_GUILD"))
            );
            GuildTimelockController timelock = GuildTimelockController(
                payable(AddressLib.get("DAO_TIMELOCK"))
            );
            SurplusGuildMinter sgm = SurplusGuildMinter(
                AddressLib.get("SURPLUS_GUILD_MINTER")
            );
            ProfitManager profitManager = ProfitManager(
                AddressLib.get("PROFIT_MANAGER")
            );
            RateLimitedMinter rateLimitedCreditMinter = RateLimitedMinter(
                AddressLib.get("RATE_LIMITED_CREDIT_MINTER")
            );
            RateLimitedMinter rateLimitedGuildMinter = RateLimitedMinter(
                AddressLib.get("RATE_LIMITED_GUILD_MINTER")
            );
            AuctionHouse auctionHouse = AuctionHouse(
                AddressLib.get("AUCTION_HOUSE")
            );
            GuildGovernor governor = GuildGovernor(
                payable(AddressLib.get("DAO_GOVERNOR_GUILD"))
            );
            GuildVetoGovernor vetoGovernorCredit = GuildVetoGovernor(
                payable(AddressLib.get("ONBOARD_VETO_CREDIT"))
            );

            assertEq(
                address(core),
                address(profitManager.core()),
                "Profit Manager Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(sgm.core()),
                "Surplus Guild Minter Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(guild.core()),
                "Guild Token Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(credit.core()),
                "Credit Token Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(timelock.core()),
                "Timelock Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(governor.core()),
                "Governor Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(onboarder.core()),
                "Onboarder Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(offboarding.core()),
                "Offboarding Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(auctionHouse.core()),
                "Auction House Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(vetoGovernorCredit.core()),
                "Veto Governor Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(rateLimitedGuildMinter.core()),
                "Rate Limited Guild Minter Incorrect Core Address"
            );
            assertEq(
                address(core),
                address(rateLimitedCreditMinter.core()),
                "Rate Limited Credit Minter Incorrect Core Address"
            );
        }

        /// PSM Verification
        {
            SimplePSM psm = SimplePSM(AddressLib.get("PSM_USDC"));

            assertEq(
                psm.pegToken(),
                AddressLib.get("ERC20_USDC"),
                "USDC PSM Incorrect Peg Token Address"
            );
            assertEq(
                psm.decimalCorrection(),
                1e12,
                "USDC PSM Incorrect Decimal Correction"
            );
            assertEq(
                psm.credit(),
                AddressLib.get("ERC20_GUSDC"),
                "USDC PSM Incorrect Credit Token Address"
            );
            assertEq(
                psm.profitManager(),
                AddressLib.get("PROFIT_MANAGER"),
                "USDC PSM Incorrect Profit Manager Address"
            );
        }

        /// Rate Limited Minter Verification
        {
            RateLimitedMinter rateLimitedCreditMinter = RateLimitedMinter(
                AddressLib.get("RATE_LIMITED_CREDIT_MINTER")
            );
            assertEq(
                rateLimitedCreditMinter.MAX_RATE_LIMIT_PER_SECOND(),
                0,
                "credit max rate limit per second"
            );
            assertEq(
                rateLimitedCreditMinter.token(),
                AddressLib.get("ERC20_GUSDC"),
                "credit token incorrect"
            );
            assertEq(
                rateLimitedCreditMinter.role(),
                CoreRoles.RATE_LIMITED_CREDIT_MINTER,
                "credit minter role incorrect"
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
                rateLimitedCreditMinter.bufferCap(),
                "credit buffer incorrect, should eq buffer cap"
            );
        }
        {
            RateLimitedMinter rateLimitedGuildMinter = RateLimitedMinter(
                AddressLib.get("RATE_LIMITED_GUILD_MINTER")
            );
            assertEq(
                rateLimitedGuildMinter.MAX_RATE_LIMIT_PER_SECOND(),
                0,
                "guild max rate limit per second"
            );
            assertEq(
                rateLimitedGuildMinter.token(),
                AddressLib.get("ERC20_GUILD"),
                "guild token incorrect address rl guild minter"
            );
            assertEq(
                rateLimitedGuildMinter.role(),
                CoreRoles.RATE_LIMITED_GUILD_MINTER,
                "guild minter role incorrect rl guild minter"
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
                ERC20MultiVotes(AddressLib.get("ERC20_GUSDC"))
                    .maxDelegates(),
                MAX_DELEGATES,
                "max delegates incorrect"
            );
            /// guild token starts non-transferrable
            assertFalse(
                GuildToken(AddressLib.get("ERC20_GUILD")).transferable(),
                "guild token should not be transferable"
            );
            assertEq(
                ERC20MultiVotes(AddressLib.get("ERC20_GUILD"))
                    .maxDelegates(),
                MAX_DELEGATES,
                "max delegates incorrect"
            );
            assertEq(
                ERC20MultiVotes(AddressLib.get("ERC20_GUILD")).totalSupply(),
                0,
                "guild total supply not 0 after deployment"
            );
            assertEq(
                ERC20MultiVotes(AddressLib.get("ERC20_GUILD")).balanceOf(
                    AddressLib.get("TEAM_MULTISIG")
                ),
                0,
                "balance of team multisig not 0 after deployment"
            );
            assertEq(
                ERC20MultiVotes(AddressLib.get("ERC20_GUSDC"))
                    .totalSupply(),
                0,
                "credit total supply not 0 after deployment"
            );
            assertEq(
                ERC20MultiVotes(AddressLib.get("ERC20_GUSDC")).balanceOf(
                    deployer
                ),
                0,
                "balance of deployer not 0 after deployment"
            );
        }
        /// PROFIT MANAGER Verification
        {
            assertEq(
                ProfitManager(AddressLib.get("PROFIT_MANAGER")).credit(),
                AddressLib.get("ERC20_GUSDC"),
                "Profit Manager credit token incorrect"
            );
            assertEq(
                ProfitManager(AddressLib.get("PROFIT_MANAGER")).guild(),
                AddressLib.get("ERC20_GUILD"),
                "Profit Manager guild token incorrect"
            );
            assertEq(
                ProfitManager(AddressLib.get("PROFIT_MANAGER"))
                    .surplusBuffer(),
                0,
                "Profit Manager surplus buffer incorrect"
            );

            (
                uint256 surplusBufferSplit,
                uint256 creditSplit,
                uint256 guildSplit,
                uint256 otherSplit,
                address otherRecipient
            ) = ProfitManager(AddressLib.get("PROFIT_MANAGER"))
                    .getProfitSharingConfig();

            assertEq(
                surplusBufferSplit,
                SURPLUS_BUFFER_SPLIT,
                "Profit Manager surplus buffer split incorrect"
            );
            assertEq(
                creditSplit,
                CREDIT_SPLIT,
                "Profit Manager credit split incorrect"
            );
            assertEq(
                guildSplit,
                GUILD_SPLIT,
                "Profit Manager guild split incorrect"
            );
            assertEq(
                otherSplit,
                OTHER_SPLIT,
                "Profit Manager other split incorrect"
            );
            assertEq(
                otherRecipient,
                OTHER_ADDRESS,
                "Profit Manager other recipient incorrect"
            );
        }
        /// TIMELOCK Verification
        {
            GuildTimelockController timelock = GuildTimelockController(
                payable(AddressLib.get("DAO_TIMELOCK"))
            );

            assertEq(
                timelock.getMinDelay(),
                DAO_TIMELOCK_DELAY,
                "DAO Timelock delay incorrect"
            );

            GuildTimelockController onboardingTimelock = GuildTimelockController(
                payable(AddressLib.get("ONBOARD_TIMELOCK"))
            );

            assertEq(
                onboardingTimelock.getMinDelay(),
                ONBOARD_TIMELOCK_DELAY,
                "Onboarding Timelock delay incorrect"
            );
        }
        /// Auction House Verification
        {
            AuctionHouse auctionHouse = AuctionHouse(
                AddressLib.get("AUCTION_HOUSE")
            );

            assertEq(
                auctionHouse.midPoint(),
                650,
                "Auction House mid point incorrect"
            );
            assertEq(
                auctionHouse.auctionDuration(),
                30 minutes,
                "Auction House duration incorrect"
            );
            assertEq(
                auctionHouse.nAuctionsInProgress(),
                0,
                "Auction House n auctions in progress incorrect"
            );
        }

        {
            ProfitManager profitManager = ProfitManager(
                AddressLib.get("PROFIT_MANAGER")
            );
            assertEq(
                profitManager.surplusBuffer(),
                0,
                "starting surplus not 0"
            );
            assertEq(
                profitManager.credit(),
                AddressLib.get("ERC20_GUSDC"),
                "credit address incorrect"
            );
            assertEq(
                profitManager.guild(),
                AddressLib.get("ERC20_GUILD"),
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
                0.09e18,
                "incorrect surplus buffer split"
            );
            assertEq(creditSplit, 0.9e18, "incorrect credit split");
            assertEq(guildSplit, 0.01e18, "incorrect guild split");
            assertEq(otherSplit, 0, "incorrect other split");
            assertEq(otherRecipient, address(0), "incorrect other recipient");
        }

        /// Governor Verification
        {
            GuildGovernor governor = GuildGovernor(
                payable(AddressLib.get("DAO_GOVERNOR_GUILD"))
            );
            assertEq(
                governor.votingDelay(),
                DAO_GOVERNOR_GUILD_VOTING_DELAY,
                "governor voting delay"
            );
            assertEq(
                governor.votingPeriod(),
                DAO_GOVERNOR_GUILD_VOTING_PERIOD,
                "governor voting period"
            );
            assertEq(
                governor.proposalThreshold(),
                DAO_GOVERNOR_GUILD_PROPOSAL_THRESHOLD,
                "proposal threshold"
            );
            assertEq(governor.quorum(0), DAO_GOVERNOR_GUILD_QUORUM, "governor quorum");

            GuildVetoGovernor vetoGovernorCredit = GuildVetoGovernor(
                payable(AddressLib.get("DAO_VETO_CREDIT"))
            );
            
            assertEq(
                vetoGovernorCredit.quorum(0),
                DAO_VETO_CREDIT_QUORUM,
                "veto governor quorum"
            );
            assertEq(
                vetoGovernorCredit.votingDelay(),
                0,
                "veto governor voting delay"
            );
            assertEq(
                vetoGovernorCredit.votingPeriod(),
                2425847,
                "veto governor voting period"
            );
            assertEq(
                address(vetoGovernorCredit.token()),
                AddressLib.get("ERC20_GUSDC"),
                "veto governor token incorrect"
            );
            
            GuildVetoGovernor vetoGovernorGuild = GuildVetoGovernor(
                payable(AddressLib.get("DAO_VETO_GUILD"))
            );
            assertEq(
                vetoGovernorGuild.quorum(0),
                DAO_VETO_GUILD_QUORUM,
                "veto governor quorum"
            );
            assertEq(
                vetoGovernorGuild.votingDelay(),
                0,
                "veto governor voting delay"
            );
            assertEq(
                vetoGovernorGuild.votingPeriod(),
                2425847,
                "veto governor voting period"
            );
            assertEq(
                address(vetoGovernorGuild.token()),
                AddressLib.get("ERC20_GUILD"),
                "veto governor token incorrect"
            );
        }
        {
            LendingTerm term = LendingTerm(AddressLib.get("TERM_SDAI_1"));
            {
                LendingTerm.LendingTermParams memory params = term
                    .getParameters();
                assertEq(
                    term.collateralToken(),
                    AddressLib.get("ERC20_SDAI"),
                    "SDAI token incorrect"
                );
                assertEq(
                    params.collateralToken,
                    AddressLib.get("ERC20_SDAI"),
                    "SDAI token incorrect from params"
                );
                assertEq(params.openingFee, 0, "Opening fee not 0");
                assertEq(
                    params.interestRate,
                    SDAI_RATE,
                    "interest rate incorrect"
                );
                assertEq(
                    params.minPartialRepayPercent,
                    0,
                    "min partial repay percent incorrect"
                );
                assertEq(
                    params.maxDelayBetweenPartialRepay,
                    0,
                    "max delay between partial repay incorrect"
                );
                assertEq(
                    params.maxDebtPerCollateralToken,
                    MAX_SDAI_CREDIT_RATIO,
                    "max debt per collateral token incorrect"
                );
            }
            {
                LendingTerm.LendingTermReferences memory params = term
                    .getReferences();

                assertEq(
                    params.profitManager,
                    AddressLib.get("PROFIT_MANAGER"),
                    "Profit Manager address incorrect"
                );
                assertEq(
                    params.guildToken,
                    AddressLib.get("ERC20_GUILD"),
                    "Guild Token address incorrect"
                );
                assertEq(
                    params.auctionHouse,
                    AddressLib.get("AUCTION_HOUSE"),
                    "Auction House address incorrect"
                );
                assertEq(
                    params.creditMinter,
                    AddressLib.get("RATE_LIMITED_CREDIT_MINTER"),
                    "Credit Minter address incorrect"
                );
                assertEq(
                    params.creditToken,
                    AddressLib.get("ERC20_GUSDC"),
                    "Credit Token address incorrect"
                );
            }
        }
    }
}
