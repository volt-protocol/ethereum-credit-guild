//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Core} from "@src/core/Core.sol";
import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {PreGuildToken} from "@src/tokens/PreGuildToken.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {GuildVetoGovernor} from "@src/governance/GuildVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";

contract Arbitrum_0_BaseContracts is Proposal {
    function name() public view virtual returns (string memory) {
        return "Arbitrum_0_BaseContracts";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Arbitrum_0_BaseContracts: wrong chain id"
        );
    }

    /// --------------------------------------------------------------
    /// --------------------------------------------------------------
    /// -------------------- DEPLOYMENT CONSTANTS --------------------
    /// --------------------------------------------------------------
    /// --------------------------------------------------------------

    /// @notice maximum guild supply is 1b tokens, however this number can change
    /// later if new tokens are minted
    uint256 internal GUILD_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice maximum delegates for guild token
    uint256 internal MAX_DELEGATES = 20;
    /// @notice maximum gauges for guild token
    uint256 internal MAX_GAUGES = 20;

    /// @notice delegate lockup period for GUILD
    uint256 internal DELEGATE_LOCKUP_PERIOD = 7 days;

    /// @notice rough estimate of `block.number` increments per day
    /// @dev see https://ycharts.com/indicators/ethereum_blocks_per_day
    uint256 public BPD = 7120;

    // governance params
    uint256 public DAO_TIMELOCK_DELAY = 4 days;
    uint256 public ONBOARD_TIMELOCK_DELAY = 1 days;
    uint256 public DAO_GOVERNOR_GUILD_VOTING_DELAY = 0 * BPD;
    uint256 public DAO_GOVERNOR_GUILD_VOTING_PERIOD = 3 * BPD;
    uint256 public DAO_GOVERNOR_GUILD_PROPOSAL_THRESHOLD = 2_500_000 * 1e18;
    uint256 public DAO_GOVERNOR_GUILD_QUORUM = 25_000_000 * 1e18;
    uint256 public DAO_VETO_GUILD_QUORUM = 15_000_000 * 1e18;
    uint256 public ONBOARD_GOVERNOR_GUILD_VOTING_DELAY = 0 * BPD;
    uint256 public ONBOARD_GOVERNOR_GUILD_VOTING_PERIOD = 2 * BPD;
    uint256 public ONBOARD_GOVERNOR_GUILD_PROPOSAL_THRESHOLD = 100_000 * 1e18;
    uint256 public ONBOARD_GOVERNOR_GUILD_QUORUM = 500_000 * 1e18;
    uint256 public ONBOARD_VETO_GUILD_QUORUM = 500_000 * 1e18;
    uint256 public OFFBOARD_QUORUM = 500_000 * 1e18;

    function deploy() public virtual {
        // Core
        {
            Core core = new Core();
            setAddr("CORE", address(core));
        }

        // Tokens & minting
        {
            GuildToken guild = new GuildToken(getAddr("CORE"));
            RateLimitedMinter rlgm = new RateLimitedMinter(
                getAddr("CORE"),
                address(guild),
                CoreRoles.RATE_LIMITED_GUILD_MINTER,
                0, // maxRateLimitPerSecond
                0, // rateLimitPerSecond
                uint128(GUILD_SUPPLY) // bufferCap
            );
            PreGuildToken preGuild = new PreGuildToken(address(rlgm));

            setAddr("ERC20_GUILD", address(guild));
            setAddr("ERC20_PREGUILD", address(preGuild));
            setAddr("RLGM", address(rlgm));
        }

        // Auction House & LendingTerm Implementation
        {
            AuctionHouse auctionHouse6h = new AuctionHouse(
                getAddr("CORE"),
                3 * 3600, // midPoint
                6 * 3600, // auctionDuration
                0 // 0% collateral offered at start
            );
            setAddr("AUCTION_HOUSE_6H", address(auctionHouse6h));

            AuctionHouse auctionHouse12h = new AuctionHouse(
                getAddr("CORE"),
                6 * 3600, // midPoint
                12 * 3600, // auctionDuration
                0 // 0% collateral offered at start
            );
            setAddr("AUCTION_HOUSE_12H", address(auctionHouse12h));

            AuctionHouse auctionHouse24h = new AuctionHouse(
                getAddr("CORE"),
                12 * 3600, // midPoint
                24 * 3600, // auctionDuration
                0 // 0% collateral offered at start
            );
            setAddr("AUCTION_HOUSE_24H", address(auctionHouse24h));

            LendingTerm termV1 = new LendingTerm();
            setAddr("LENDING_TERM_V1", address(termV1));
        }

        // Governance
        {
            GuildTimelockController daoTimelock = new GuildTimelockController(
                getAddr("CORE"),
                DAO_TIMELOCK_DELAY
            );
            GuildGovernor daoGovernorGuild = new GuildGovernor(
                getAddr("CORE"),
                address(daoTimelock),
                getAddr("ERC20_GUILD"),
                DAO_GOVERNOR_GUILD_VOTING_DELAY, // initialVotingDelay
                DAO_GOVERNOR_GUILD_VOTING_PERIOD, // initialVotingPeriod
                DAO_GOVERNOR_GUILD_PROPOSAL_THRESHOLD, // initialProposalThreshold
                DAO_GOVERNOR_GUILD_QUORUM // initialQuorum
            );
            GuildVetoGovernor daoVetoGuild = new GuildVetoGovernor(
                getAddr("CORE"),
                address(daoTimelock),
                getAddr("ERC20_GUILD"),
                DAO_VETO_GUILD_QUORUM // initialQuorum
            );

            GuildTimelockController onboardTimelock = new GuildTimelockController(
                    getAddr("CORE"),
                    ONBOARD_TIMELOCK_DELAY
                );
            LendingTermFactory termFactory = new LendingTermFactory(
                getAddr("CORE"), // _core
                getAddr("ERC20_GUILD") // _guildToken
            );
            LendingTermOnboarding onboardGovernorGuild = new LendingTermOnboarding(
                getAddr("CORE"), // _core
                address(onboardTimelock), // _timelock
                getAddr("ERC20_GUILD"), // _guildToken
                ONBOARD_GOVERNOR_GUILD_VOTING_DELAY, // initialVotingDelay
                ONBOARD_GOVERNOR_GUILD_VOTING_PERIOD, // initialVotingPeriod
                ONBOARD_GOVERNOR_GUILD_PROPOSAL_THRESHOLD, // initialProposalThreshold
                ONBOARD_GOVERNOR_GUILD_QUORUM, // initialQuorum
                address(termFactory)
            );
            GuildVetoGovernor onboardVetoGuild = new GuildVetoGovernor(
                getAddr("CORE"),
                address(onboardTimelock),
                getAddr("ERC20_GUILD"),
                ONBOARD_VETO_GUILD_QUORUM // initialQuorum
            );
            LendingTermOffboarding termOffboarding = new LendingTermOffboarding(
                getAddr("CORE"),
                getAddr("ERC20_GUILD"),
                address(termFactory),
                OFFBOARD_QUORUM // quorum
            );

            setAddr("LENDING_TERM_FACTORY", address(termFactory));
            setAddr("DAO_GOVERNOR_GUILD", address(daoGovernorGuild));
            setAddr("DAO_TIMELOCK", address(daoTimelock));
            setAddr("DAO_VETO_GUILD", address(daoVetoGuild));
            setAddr("ONBOARD_GOVERNOR_GUILD", address(onboardGovernorGuild));
            setAddr("ONBOARD_TIMELOCK", address(onboardTimelock));
            setAddr("ONBOARD_VETO_GUILD", address(onboardVetoGuild));
            setAddr("OFFBOARD_GOVERNOR_GUILD", address(termOffboarding));
        }

        // Terms factory setup
        {
            LendingTermFactory termFactory = LendingTermFactory(
                payable(getAddr("LENDING_TERM_FACTORY"))
            );

            termFactory.allowImplementation(getAddr("LENDING_TERM_V1"), true);
            termFactory.allowAuctionHouse(getAddr("AUCTION_HOUSE_6H"), true);
            termFactory.allowAuctionHouse(getAddr("AUCTION_HOUSE_12H"), true);
            termFactory.allowAuctionHouse(getAddr("AUCTION_HOUSE_24H"), true);
        }
    }

    function afterDeploy(address deployer) public virtual {
        Core core = Core(getAddr("CORE"));

        // grant roles to smart contracts
        bytes32[] memory roles = new bytes32[](1000);
        address[] memory addrs = new address[](1000);
        uint256 n = 0;

        // GOVERNOR
        roles[n] = CoreRoles.GOVERNOR;
        addrs[n++] = getAddr("DAO_TIMELOCK");
        roles[n] = CoreRoles.GOVERNOR;
        addrs[n++] = getAddr("ONBOARD_TIMELOCK");
        roles[n] = CoreRoles.GOVERNOR;
        addrs[n++] = getAddr("OFFBOARD_GOVERNOR_GUILD");

        // GUARDIAN
        roles[n] = CoreRoles.GUARDIAN;
        addrs[n++] = getAddr("TEAM_MULTISIG");

        // GUILD_MINTER
        roles[n] = CoreRoles.GUILD_MINTER;
        addrs[n++] = getAddr("RLGM");

        /// RATE_LIMITED_GUILD_MINTER
        roles[n] = CoreRoles.RATE_LIMITED_GUILD_MINTER;
        addrs[n++] = getAddr("ERC20_PREGUILD");

        // GAUGE_ADD
        roles[n] = CoreRoles.GAUGE_ADD;
        addrs[n++] = getAddr("DAO_TIMELOCK");
        roles[n] = CoreRoles.GAUGE_ADD;
        addrs[n++] = getAddr("ONBOARD_TIMELOCK");
        roles[n] = CoreRoles.GAUGE_ADD;
        addrs[n++] = deployer;

        // GAUGE_REMOVE
        roles[n] = CoreRoles.GAUGE_REMOVE;
        addrs[n++] = getAddr("DAO_TIMELOCK");
        roles[n] = CoreRoles.GAUGE_REMOVE;
        addrs[n++] = getAddr("OFFBOARD_GOVERNOR_GUILD");

        // GAUGE_PARAMETERS
        roles[n] = CoreRoles.GAUGE_PARAMETERS;
        addrs[n++] = getAddr("DAO_TIMELOCK");
        roles[n] = CoreRoles.GAUGE_PARAMETERS;
        addrs[n++] = deployer;

        // GUILD_GOVERNANCE_PARAMETERS
        roles[n] = CoreRoles.GUILD_GOVERNANCE_PARAMETERS;
        addrs[n++] = getAddr("DAO_TIMELOCK");
        roles[n] = CoreRoles.GUILD_GOVERNANCE_PARAMETERS;
        addrs[n++] = deployer;

        // CREDIT_GOVERNANCE_PARAMETERS
        roles[n] = CoreRoles.CREDIT_GOVERNANCE_PARAMETERS;
        addrs[n++] = getAddr("DAO_TIMELOCK");
        roles[n] = CoreRoles.CREDIT_GOVERNANCE_PARAMETERS;
        addrs[n++] = deployer;

        // CREDIT_REBASE_PARAMETERS
        roles[n] = CoreRoles.CREDIT_REBASE_PARAMETERS;
        addrs[n++] = getAddr("DAO_TIMELOCK");

        // TIMELOCK_PROPOSER
        roles[n] = CoreRoles.TIMELOCK_PROPOSER;
        addrs[n++] = getAddr("DAO_GOVERNOR_GUILD");
        roles[n] = CoreRoles.TIMELOCK_PROPOSER;
        addrs[n++] = getAddr("ONBOARD_GOVERNOR_GUILD");

        // TIMELOCK_EXECUTOR
        roles[n] = CoreRoles.TIMELOCK_EXECUTOR;
        addrs[n++] = address(0);

        // TIMELOCK_CANCELLER
        roles[n] = CoreRoles.TIMELOCK_CANCELLER;
        addrs[n++] = getAddr("DAO_VETO_GUILD");
        roles[n] = CoreRoles.TIMELOCK_CANCELLER;
        addrs[n++] = getAddr("ONBOARD_VETO_GUILD");
        roles[n] = CoreRoles.TIMELOCK_CANCELLER;
        addrs[n++] = getAddr("DAO_GOVERNOR_GUILD");
        roles[n] = CoreRoles.TIMELOCK_CANCELLER;
        addrs[n++] = getAddr("ONBOARD_GOVERNOR_GUILD");

        // grant roles
        bytes32[] memory _roles = new bytes32[](n);
        address[] memory _addrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            _roles[i] = roles[i];
            _addrs[i] = addrs[i];
        }
        core.grantRoles(_roles, _addrs);

        // Configuration
        GuildToken(getAddr("ERC20_GUILD")).setMaxGauges(MAX_GAUGES);
        GuildToken(getAddr("ERC20_GUILD")).setMaxDelegates(MAX_DELEGATES);
        GuildToken(getAddr("ERC20_GUILD")).setDelegateLockupPeriod(
            DELEGATE_LOCKUP_PERIOD
        );

        core.renounceRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, deployer);
        core.renounceRole(CoreRoles.GAUGE_PARAMETERS, deployer);
    }

    function run(address deployer) public pure virtual {}

    function teardown(address deployer) public pure virtual {}

    function validate(address deployer) public pure virtual {}
}
