//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {GovernorProposal} from "@test/proposals/proposalTypes/GovernorProposal.sol";
import {GuildVetoGovernor} from "@src/governance/GuildVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {TestnetToken} from "@src/tokens/TestnetToken.sol";

contract Arbitrum_10_MarketstUSD is GovernorProposal {
    function name() public view virtual returns (string memory) {
        return "Arbitrum_10_MarketstUSD";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Arbitrum_10_MarketstUSD: wrong chain id"
        );
    }

    function _mkt(
        string memory addressLabel
    ) private pure returns (string memory) {
        return string.concat(Strings.toString(MARKET_ID), addressLabel);
    }

    /// --------------------------------------------------------------
    /// --------------------------------------------------------------
    /// -------------------- DEPLOYMENT CONSTANTS --------------------
    /// --------------------------------------------------------------
    /// --------------------------------------------------------------

    string internal constant PEG_TOKEN = "stUSD";
    uint256 internal constant MARKET_ID = 8; // gauge type / market ID

    /// @notice guild mint ratio is 10e18, meaning for 1 credit 10 guild tokens are
    /// minted in SurplusGuildMinter
    uint256 internal constant GUILD_MINT_RATIO = 10e18;

    /// @notice ratio of guild tokens received per Credit earned in
    /// the Surplus Guild Minter
    uint256 internal constant GUILD_CREDIT_REWARD_RATIO = 20 * 1e18;

    /// @notice min borrow size in the market at launch
    uint256 internal constant MIN_BORROW = 300 * 1e18;

    /// @notice max total borrows in the market at launch
    uint256 internal constant MAX_TOTAL_ISSUANCE = 2_000_000 * 1e18;

    /// @notice gauge weight tolerance in the market at launch
    uint256 internal constant GAUGE_WEIGHT_TOLERANCE = 9e18;

    /// @notice buffer cap
    uint256 internal constant RLCM_BUFFER_CAP = 1_000_000 * 1e18; // 1M

    /// @notice rate limit per second
    uint256 internal constant RLCM_BUFFER_REPLENISH = 11.574e18; // ~1M/day

    /// ------------------------------------------------------------------------
    /// profit sharing configuration parameters for the Profit Manager
    /// ------------------------------------------------------------------------

    /// @notice 5% of profits go to the surplus buffer
    uint256 internal constant SURPLUS_BUFFER_SPLIT = 0.05e18;

    /// @notice 90% of profits go to credit holders that opt into rebasing
    uint256 internal constant CREDIT_SPLIT = 0.90e18;

    /// @notice 5% of profits go to guild holders staked in gauges
    uint256 internal constant GUILD_SPLIT = 0.05e18;

    /// @notice 0% of profits go to other
    uint256 internal constant OTHER_SPLIT = 0;
    address internal constant OTHER_ADDRESS = address(0);

    // governance params
    uint256 public constant DAO_VETO_CREDIT_QUORUM = 5_000_000e18;
    uint256 public constant ONBOARD_VETO_CREDIT_QUORUM = 1_000_000e18;

    uint256 public constant INITIAL_MINT = 10e18;

    function deploy() public virtual {
        // ProfitManager
        {
            ProfitManager profitManager = new ProfitManager(getAddr("CORE"));
            setAddr(_mkt("_PROFIT_MANAGER"), address(profitManager));
        }

        // Tokens & minting
        {
            CreditToken credit = new CreditToken(
                getAddr("CORE"),
                string.concat(
                    "ECG ",
                    PEG_TOKEN,
                    "-",
                    Strings.toString(MARKET_ID)
                ),
                string.concat("g", PEG_TOKEN, "-", Strings.toString(MARKET_ID))
            );
            RateLimitedMinter rlcm = new RateLimitedMinter(
                getAddr("CORE"),
                address(credit),
                CoreRoles.RATE_LIMITED_CREDIT_MINTER,
                type(uint256).max, // maxRateLimitPerSecond
                uint128(RLCM_BUFFER_REPLENISH), // rateLimitPerSecond
                uint128(RLCM_BUFFER_CAP) // bufferCap
            );
            SurplusGuildMinter sgm = new SurplusGuildMinter(
                getAddr("CORE"),
                getAddr(_mkt("_PROFIT_MANAGER")),
                address(credit),
                getAddr("ERC20_GUILD"),
                getAddr("RLGM"),
                GUILD_MINT_RATIO, // ratio of GUILD minted per CREDIT staked
                GUILD_CREDIT_REWARD_RATIO // amount of GUILD received per CREDIT earned from staking in Gauges
            );

            setAddr(_mkt("_CREDIT"), address(credit));
            setAddr(_mkt("_RLCM"), address(rlcm));
            setAddr(_mkt("_SGM"), address(sgm));
        }

        // PSM
        {
            SimplePSM psm = new SimplePSM(
                getAddr("CORE"),
                getAddr(_mkt("_PROFIT_MANAGER")),
                getAddr(_mkt("_CREDIT")),
                getAddr(string.concat("ERC20_", PEG_TOKEN))
            );

            setAddr(_mkt("_PSM"), address(psm));
            setAddr(_mkt("_PEG_TOKEN"), psm.pegToken());
        }

        // Governance
        {
            GuildVetoGovernor daoVetoCredit = new GuildVetoGovernor(
                getAddr("CORE"),
                getAddr("DAO_TIMELOCK"),
                getAddr(_mkt("_CREDIT")),
                DAO_VETO_CREDIT_QUORUM // initialQuorum
            );
            GuildVetoGovernor onboardVetoCredit = new GuildVetoGovernor(
                getAddr("CORE"),
                getAddr("ONBOARD_TIMELOCK"),
                getAddr(_mkt("_CREDIT")),
                ONBOARD_VETO_CREDIT_QUORUM // initialQuorum
            );

            setAddr(_mkt("_DAO_VETO_CREDIT"), address(daoVetoCredit));
            setAddr(_mkt("_ONBOARD_VETO_CREDIT"), address(onboardVetoCredit));
        }
    }

    function afterDeploy(address/* deployer*/) public virtual {
        vm.prank(0x8f8BccE4c180B699F81499005281fA89440D1e95);
        ERC20(getAddr(_mkt("_PEG_TOKEN"))).transfer(getAddr("DAO_TIMELOCK"), INITIAL_MINT);
    }

    function run(address /* deployer*/) public virtual {
        // grant roles to smart contracts
        bytes32[] memory roles = new bytes32[](1000);
        address[] memory addrs = new address[](1000);
        uint256 n = 0;

        // CREDIT_MINTER
        roles[n] = CoreRoles.CREDIT_MINTER;
        addrs[n++] = getAddr(_mkt("_RLCM"));
        roles[n] = CoreRoles.CREDIT_MINTER;
        addrs[n++] = getAddr(_mkt("_PSM"));

        // CREDIT_BURNER
        roles[n] = CoreRoles.CREDIT_BURNER;
        addrs[n++] = getAddr(_mkt("_PROFIT_MANAGER"));
        roles[n] = CoreRoles.CREDIT_BURNER;
        addrs[n++] = getAddr(_mkt("_PSM"));

        /// RATE_LIMITED_GUILD_MINTER
        roles[n] = CoreRoles.RATE_LIMITED_GUILD_MINTER;
        addrs[n++] = getAddr(_mkt("_SGM"));

        // GUILD_SURPLUS_BUFFER_WITHDRAW
        roles[n] = CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW;
        addrs[n++] = getAddr(_mkt("_SGM"));

        // CREDIT_REBASE_PARAMETERS
        roles[n] = CoreRoles.CREDIT_REBASE_PARAMETERS;
        addrs[n++] = getAddr(_mkt("_PSM"));

        // TIMELOCK_CANCELLER
        roles[n] = CoreRoles.TIMELOCK_CANCELLER;
        addrs[n++] = getAddr(_mkt("_DAO_VETO_CREDIT"));
        roles[n] = CoreRoles.TIMELOCK_CANCELLER;
        addrs[n++] = getAddr(_mkt("_ONBOARD_VETO_CREDIT"));

        // Roles
        bytes32[] memory _roles = new bytes32[](n);
        address[] memory _addrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            _roles[i] = roles[i];
            _addrs[i] = addrs[i];
        }
        _addStep(
            getAddr("CORE"),
            abi.encodeWithSignature(
                "grantRoles(bytes32[],address[])",
                _roles,
                _addrs
            ),
            string.concat(
                "Grant roles to deployed contracts [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );

        // Configuration
        GuildToken guild = GuildToken(getAddr("ERC20_GUILD"));
        _addStep(
            getAddr("LENDING_TERM_FACTORY"),
            abi.encodeWithSignature(
                "setMarketReferences(uint256,(address,address,address,address))",
                MARKET_ID,
                LendingTermFactory.MarketReferences({
                    profitManager: getAddr(_mkt("_PROFIT_MANAGER")),
                    creditMinter: getAddr(_mkt("_RLCM")),
                    creditToken: getAddr(_mkt("_CREDIT")),
                    psm: getAddr(_mkt("_PSM"))
                })
            ),
            string.concat(
                "Set references in the LendingTermFactory [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr(_mkt("_PROFIT_MANAGER")),
            abi.encodeWithSignature(
                "initializeReferences(address,address)",
                getAddr(_mkt("_CREDIT")),
                getAddr("ERC20_GUILD")
            ),
            string.concat(
                "ProfitManager.initializeReferences() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr(_mkt("_PROFIT_MANAGER")),
            abi.encodeWithSignature(
                "setProfitSharingConfig(uint256,uint256,uint256,uint256,address)",
                SURPLUS_BUFFER_SPLIT,
                CREDIT_SPLIT,
                GUILD_SPLIT,
                OTHER_SPLIT,
                OTHER_ADDRESS
            ),
            string.concat(
                "ProfitManager.setProfitSharingConfig() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr(_mkt("_PROFIT_MANAGER")),
            abi.encodeWithSignature("setMinBorrow(uint256)", MIN_BORROW),
            string.concat(
                "ProfitManager.setMinBorrow() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr(_mkt("_PROFIT_MANAGER")),
            abi.encodeWithSignature(
                "setMaxTotalIssuance(uint256)",
                MAX_TOTAL_ISSUANCE
            ),
            string.concat(
                "ProfitManager.setMaxTotalIssuance() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr(_mkt("_PROFIT_MANAGER")),
            abi.encodeWithSignature(
                "setGaugeWeightTolerance(uint256)",
                GAUGE_WEIGHT_TOLERANCE
            ),
            string.concat(
                "ProfitManager.setGaugeWeightTolerance() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr(_mkt("_CREDIT")),
            abi.encodeWithSignature(
                "setMaxDelegates(uint256)",
                guild.maxDelegates()
            ),
            string.concat(
                "CreditToken.setMaxDelegates() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr(_mkt("_CREDIT")),
            abi.encodeWithSignature(
                "setDelegateLockupPeriod(uint256)",
                guild.delegateLockupPeriod()
            ),
            string.concat(
                "CreditToken.setDelegateLockupPeriod() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr("ERC20_GUILD"),
            abi.encodeWithSignature(
                "setCanExceedMaxGauges(address,bool)",
                getAddr(_mkt("_SGM")),
                true
            ),
            string.concat(
                "GuildToken.setCanExceedMaxGauges() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        // Initial mint
        _addStep(
            getAddr(string.concat("ERC20_", PEG_TOKEN)),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                getAddr(_mkt("_PSM")),
                INITIAL_MINT
            ),
            string.concat(
                "Approve ",
                PEG_TOKEN,
                " on PSM for initial mintAndEnterRebase() [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );
        _addStep(
            getAddr(_mkt("_PSM")),
            abi.encodeWithSignature(
                "mintAndEnterRebase(uint256)",
                INITIAL_MINT
            ),
            string.concat(
                "Initial PSM.mintAndEnterRebase() with ",
                Strings.toString(INITIAL_MINT),
                " ",
                PEG_TOKEN,
                " [market ",
                Strings.toString(MARKET_ID),
                "]"
            )
        );

        // Propose to the DAO
        address governor = getAddr("DAO_GOVERNOR_GUILD");
        address proposer = getAddr("TEAM_MULTISIG");
        address voter = getAddr("TEAM_MULTISIG");
        DEBUG = true;
        _simulateGovernorSteps(name(), governor, proposer, voter);
    }

    function teardown(address deployer) public pure virtual {}

    function validate(address deployer) public pure virtual {}
}
