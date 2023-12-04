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
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {VoltTimelockController} from "@src/governance/VoltTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";

contract Proposal_0 is Proposal {
    string public name = "Proposal_0";

    uint256 public constant BLOCKS_PER_DAY = 7164;

    // governance params
    uint256 public constant DAO_TIMELOCK_DELAY = 7 days;
    uint256 public constant ONBOARD_TIMELOCK_DELAY = 1 days;
    uint256 public constant DAO_GOVERNOR_GUILD_VOTING_DELAY = 0 * BLOCKS_PER_DAY;
    uint256 public constant DAO_GOVERNOR_GUILD_VOTING_PERIOD = 3 * BLOCKS_PER_DAY;
    uint256 public constant DAO_GOVERNOR_GUILD_PROPOSAL_THRESHOLD = 2_500_000e18;
    uint256 public constant DAO_GOVERNOR_GUILD_QUORUM = 25_000_000e18;
    uint256 public constant DAO_VETO_CREDIT_QUORUM = 5_000_000e18;
    uint256 public constant DAO_VETO_GUILD_QUORUM = 15_000_000e18;
    uint256 public constant ONBOARD_GOVERNOR_GUILD_VOTING_DELAY = 0 * BLOCKS_PER_DAY;
    uint256 public constant ONBOARD_GOVERNOR_GUILD_VOTING_PERIOD = 2 * BLOCKS_PER_DAY;
    uint256 public constant ONBOARD_GOVERNOR_GUILD_PROPOSAL_THRESHOLD = 1_000_000e18;
    uint256 public constant ONBOARD_GOVERNOR_GUILD_QUORUM = 10_000_000e18;
    uint256 public constant ONBOARD_VETO_CREDIT_QUORUM = 5_000_000e18;
    uint256 public constant ONBOARD_VETO_GUILD_QUORUM = 10_000_000e18;
    uint256 public constant OFFBOARD_QUORUM = 10_000_000e18;

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
                address(guild),
                CoreRoles.RATE_LIMITED_GUILD_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                1_000_000_000e18 // bufferCap
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

        // Auction House & LendingTerm Implementation V1 & PSM
        {
            AuctionHouse auctionHouse = new AuctionHouse(
                addresses.mainnet("CORE"),
                650, // midPoint = 10m50s
                1800 // auctionDuration = 30m
            );

            LendingTerm termV1 = new LendingTerm();

            SimplePSM psm = new SimplePSM(
                addresses.mainnet("CORE"),
                addresses.mainnet("PROFIT_MANAGER"),
                addresses.mainnet("ERC20_CREDIT"),
                addresses.mainnet("ERC20_USDC")
            );

            addresses.addMainnet("AUCTION_HOUSE_1", address(auctionHouse));
            addresses.addMainnet("LENDING_TERM_V1", address(termV1));
            addresses.addMainnet("PSM_USDC", address(psm));
        }

        // Governance
        {
            VoltTimelockController daoTimelock = new VoltTimelockController(
                addresses.mainnet("CORE"),
                DAO_TIMELOCK_DELAY
            );
            VoltGovernor daoGovernorGuild = new VoltGovernor(
                addresses.mainnet("CORE"),
                address(daoTimelock),
                addresses.mainnet("ERC20_GUILD"),
                DAO_GOVERNOR_GUILD_VOTING_DELAY, // initialVotingDelay
                DAO_GOVERNOR_GUILD_VOTING_PERIOD, // initialVotingPeriod
                DAO_GOVERNOR_GUILD_PROPOSAL_THRESHOLD, // initialProposalThreshold
                DAO_GOVERNOR_GUILD_QUORUM // initialQuorum
            );
            VoltVetoGovernor daoVetoCredit = new VoltVetoGovernor(
                addresses.mainnet("CORE"),
                address(daoTimelock),
                addresses.mainnet("ERC20_CREDIT"),
                DAO_VETO_CREDIT_QUORUM // initialQuorum
            );
            VoltVetoGovernor daoVetoGuild = new VoltVetoGovernor(
                addresses.mainnet("CORE"),
                address(daoTimelock),
                addresses.mainnet("ERC20_GUILD"),
                DAO_VETO_GUILD_QUORUM // initialQuorum
            );

            VoltTimelockController onboardTimelock = new VoltTimelockController(
                addresses.mainnet("CORE"),
                ONBOARD_TIMELOCK_DELAY
            );
            LendingTermOnboarding onboardGovernorGuild = new LendingTermOnboarding(
                LendingTerm.LendingTermReferences({
                    profitManager: addresses.mainnet("PROFIT_MANAGER"),
                    guildToken: addresses.mainnet("ERC20_GUILD"),
                    auctionHouse: addresses.mainnet("AUCTION_HOUSE_V1"),
                    creditMinter: addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"),
                    creditToken: addresses.mainnet("ERC20_CREDIT")
                }), /// _lendingTermReferences
                1, // _gaugeType
                addresses.mainnet("CORE"), // _core
                address(onboardTimelock), // _timelock
                ONBOARD_GOVERNOR_GUILD_VOTING_DELAY, // initialVotingDelay
                ONBOARD_GOVERNOR_GUILD_VOTING_PERIOD, // initialVotingPeriod
                ONBOARD_GOVERNOR_GUILD_PROPOSAL_THRESHOLD, // initialProposalThreshold
                ONBOARD_GOVERNOR_GUILD_QUORUM // initialQuorum
            );
            VoltVetoGovernor onboardVetoCredit = new VoltVetoGovernor(
                addresses.mainnet("CORE"),
                address(onboardTimelock),
                addresses.mainnet("ERC20_CREDIT"),
                ONBOARD_VETO_CREDIT_QUORUM // initialQuorum
            );
            VoltVetoGovernor onboardVetoGuild = new VoltVetoGovernor(
                addresses.mainnet("CORE"),
                address(onboardTimelock),
                addresses.mainnet("ERC20_GUILD"),
                ONBOARD_VETO_GUILD_QUORUM // initialQuorum
            );

            LendingTermOffboarding termOffboarding = new LendingTermOffboarding(
                addresses.mainnet("CORE"),
                addresses.mainnet("ERC20_GUILD"),
                addresses.mainnet("PSM_USDC"),
                OFFBOARD_QUORUM // quorum
            );

            addresses.addMainnet("DAO_GOVERNOR_GUILD", address(daoGovernorGuild));
            addresses.addMainnet("DAO_TIMELOCK", address(daoTimelock));
            addresses.addMainnet("DAO_VETO_CREDIT", address(daoVetoCredit));
            addresses.addMainnet("DAO_VETO_GUILD", address(daoVetoGuild));
            addresses.addMainnet("ONBOARD_GOVERNOR_GUILD", address(onboardGovernorGuild));
            addresses.addMainnet("ONBOARD_TIMELOCK", address(onboardTimelock));
            addresses.addMainnet("ONBOARD_VETO_CREDIT", address(onboardVetoCredit));
            addresses.addMainnet("ONBOARD_VETO_GUILD", address(onboardVetoGuild));
            addresses.addMainnet("OFFBOARD_GOVERNOR_GUILD", address(termOffboarding));
        }

        // Terms
        {
            LendingTermOnboarding termOnboarding = LendingTermOnboarding(
                payable(addresses.mainnet("ONBOARD_GOVERNOR_GUILD"))
            );
            address _lendingTermV1 = addresses.mainnet("LENDING_TERM_V1");
            termOnboarding.allowImplementation(_lendingTermV1, true);

            address termUSDC1 = termOnboarding.createTerm(
                _lendingTermV1,
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet("ERC20_USDC"),
                    maxDebtPerCollateralToken: 1e30, // 1 CREDIT per USDC collateral + 12 decimals correction
                    interestRate: 0, // 0%
                    maxDelayBetweenPartialRepay: 0,// no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    hardCap: 2_000_000e18 // max 2M CREDIT issued
                })
            );
            address termSDAI1 = termOnboarding.createTerm(
                _lendingTermV1,
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet("ERC20_SDAI"),
                    maxDebtPerCollateralToken: 1e18, // 1 CREDIT per SDAI collateral + no decimals correction
                    interestRate: 0.03e18, // 3%
                    maxDelayBetweenPartialRepay: 0,// no periodic partial repay needed
                    minPartialRepayPercent: 0, // no minimum size for partial repay
                    openingFee: 0, // 0%
                    hardCap: 2_000_000e18 // max 2M CREDIT issued
                })
            );

            addresses.addMainnet("TERM_USDC_1", termUSDC1);
            addresses.addMainnet("TERM_SDAI_1", termSDAI1);
        }
    }

    function afterDeploy(Addresses addresses, address deployer) public {
        Core core = Core(addresses.mainnet("CORE"));

        // grant roles to smart contracts
        // GOVERNOR
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet("DAO_TIMELOCK"));
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet("ONBOARD_TIMELOCK"));
        core.grantRole(CoreRoles.GOVERNOR, addresses.mainnet("OFFBOARD_GOVERNOR_GUILD"));

        // GUARDIAN
        core.grantRole(CoreRoles.GUARDIAN, addresses.mainnet("TEAM_MULTISIG"));

        // CREDIT_MINTER
        core.grantRole(CoreRoles.CREDIT_MINTER, addresses.mainnet("RATE_LIMITED_CREDIT_MINTER"));
        core.grantRole(CoreRoles.CREDIT_MINTER, addresses.mainnet("PSM_USDC"));

        // RATE_LIMITED_CREDIT_MINTER
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, addresses.mainnet("TERM_USDC_1"));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, addresses.mainnet("TERM_SDAI_1"));

        // GUILD_MINTER
        core.grantRole(CoreRoles.GUILD_MINTER, addresses.mainnet("RATE_LIMITED_GUILD_MINTER"));

        // RATE_LIMITED_GUILD_MINTER
        core.grantRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, addresses.mainnet("SURPLUS_GUILD_MINTER"));

        // GAUGE_ADD
        core.grantRole(CoreRoles.GAUGE_ADD, addresses.mainnet("DAO_TIMELOCK"));
        core.grantRole(CoreRoles.GAUGE_ADD, addresses.mainnet("ONBOARD_TIMELOCK"));
        core.grantRole(CoreRoles.GAUGE_ADD, deployer);

        // GAUGE_REMOVE
        core.grantRole(CoreRoles.GAUGE_REMOVE, addresses.mainnet("DAO_TIMELOCK"));
        core.grantRole(CoreRoles.GAUGE_REMOVE, addresses.mainnet("OFFBOARD_GOVERNOR_GUILD"));

        // GAUGE_PARAMETERS
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, addresses.mainnet("DAO_TIMELOCK"));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, deployer);

        // GAUGE_PNL_NOTIFIER
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, addresses.mainnet("TERM_USDC_1"));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, addresses.mainnet("TERM_SDAI_1"));

        // GUILD_GOVERNANCE_PARAMETERS
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, addresses.mainnet("DAO_TIMELOCK"));
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);

        // GUILD_SURPLUS_BUFFER_WITHDRAW
        core.grantRole(CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW, addresses.mainnet("SURPLUS_GUILD_MINTER"));

        // CREDIT_GOVERNANCE_PARAMETERS
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, addresses.mainnet("DAO_TIMELOCK"));
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, deployer);

        // CREDIT_REBASE_PARAMETERS
        core.grantRole(CoreRoles.CREDIT_REBASE_PARAMETERS, addresses.mainnet("DAO_TIMELOCK"));
        core.grantRole(CoreRoles.CREDIT_REBASE_PARAMETERS, addresses.mainnet("PSM_USDC"));

        // TIMELOCK_PROPOSER
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, addresses.mainnet("DAO_GOVERNOR_GUILD"));
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, addresses.mainnet("ONBOARD_GOVERNOR_GUILD"));

        // TIMELOCK_EXECUTOR
        core.grantRole(CoreRoles.TIMELOCK_EXECUTOR, address(0)); // anyone can execute

        // TIMELOCK_CANCELLER
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, addresses.mainnet("DAO_VETO_CREDIT"));
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, addresses.mainnet("DAO_VETO_GUILD"));
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, addresses.mainnet("ONBOARD_VETO_CREDIT"));
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, addresses.mainnet("ONBOARD_VETO_GUILD"));

        // Configuration
        ProfitManager(addresses.mainnet("PROFIT_MANAGER")).initializeReferences(
            addresses.mainnet("ERC20_CREDIT"),
            addresses.mainnet("ERC20_GUILD"),
            addresses.mainnet("PSM_USDC")
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
