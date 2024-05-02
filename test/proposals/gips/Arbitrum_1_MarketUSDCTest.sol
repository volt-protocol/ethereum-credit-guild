//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
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
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {TestnetToken} from "@src/tokens/TestnetToken.sol";

contract Arbitrum_1_MarketUSDCTest is Proposal {
    function name() public view virtual returns (string memory) {
        return "Arbitrum_1_MarketUSDCTest";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Arbitrum_1_MarketUSDCTest: wrong chain id"
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

    uint256 internal constant MARKET_ID = 999999999; // gauge type / market ID

    /// @notice guild mint ratio is 10e18, meaning for 1 credit 10 guild tokens are
    /// minted in SurplusGuildMinter
    uint256 internal constant GUILD_MINT_RATIO = 10e18;

    /// @notice ratio of guild tokens received per Credit earned in
    /// the Surplus Guild Minter
    uint256 internal constant GUILD_CREDIT_REWARD_RATIO = 20 * 1e18;

    /// @notice min borrow size in the market at launch
    uint256 internal constant MIN_BORROW = 10 * 1e18;

    /// @notice max total borrows in the market at launch
    uint256 internal constant MAX_TOTAL_ISSUANCE = 1_000 * 1e18;

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
    uint256 public constant DAO_VETO_CREDIT_QUORUM = type(uint256).max;
    uint256 public constant ONBOARD_VETO_CREDIT_QUORUM = type(uint256).max;

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
                "ECG USDC-999999999",
                "gUSDC-999999999"
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
                getAddr("ERC20_USDC")
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

        // Terms
        {
            LendingTermFactory termFactory = LendingTermFactory(
                payable(getAddr("LENDING_TERM_FACTORY"))
            );
            termFactory.setMarketReferences(
                MARKET_ID,
                LendingTermFactory.MarketReferences({
                    profitManager: getAddr(_mkt("_PROFIT_MANAGER")),
                    creditMinter: getAddr(_mkt("_RLCM")),
                    creditToken: getAddr(_mkt("_CREDIT")),
                    psm: getAddr(_mkt("_PSM"))
                })
            );

            // WETH lending terms
            {
                uint72[2] memory borrowRatios = [
                    // 18 decimals -> no correction needed
                    100e18,
                    150e18
                ];
                uint64[4] memory interestRates = [
                    0.08e18,
                    0.12e18,
                    0.16e18,
                    0.20e18
                ];
                string[8] memory labels = [
                    _mkt("_TERM_WETH_100_08%"),
                    _mkt("_TERM_WETH_100_12%"),
                    _mkt("_TERM_WETH_100_16%"),
                    _mkt("_TERM_WETH_100_20%"),
                    _mkt("_TERM_WETH_150_08%"),
                    _mkt("_TERM_WETH_150_12%"),
                    _mkt("_TERM_WETH_150_16%"),
                    _mkt("_TERM_WETH_150_20%")
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_6H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_WETH"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: (i == 0 && j == 0) ? 3 hours : 0,
                                        minPartialRepayPercent: (i == 0 && j == 0) ? 0.1e18 : 0,
                                        openingFee: (i == 0 && j == 0) ? 0.02e18 : 0,
                                        hardCap: 10_000_000e18
                                    })
                                )
                            )
                        );
                    }
                }
            }
        }
    }

    function afterDeploy(address /* deployer*/) public virtual {
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

        // For each term:
        // - add gauge
        // - grant CREDIT_BURNER role
        // - grant RATE_LIMITED_CREDIT_MINTER role
        // - grant GAUGE_PNL_NOTIFIER role
        GuildToken guild = GuildToken(getAddr("ERC20_GUILD"));
        RecordedAddress[] memory addresses = _read();
        string memory search = string.concat(
            Strings.toString(MARKET_ID),
            "_TERM_"
        );
        for (uint256 i = 0; i < addresses.length; i++) {
            if (_contains(search, addresses[i].name)) {
                guild.addGauge(MARKET_ID, addresses[i].addr);
                roles[n] = CoreRoles.CREDIT_BURNER;
                addrs[n++] = addresses[i].addr;
                roles[n] = CoreRoles.RATE_LIMITED_CREDIT_MINTER;
                addrs[n++] = addresses[i].addr;
                roles[n] = CoreRoles.GAUGE_PNL_NOTIFIER;
                addrs[n++] = addresses[i].addr;
            }
        }

        // grant roles
        bytes32[] memory _roles = new bytes32[](n);
        address[] memory _addrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            _roles[i] = roles[i];
            _addrs[i] = addrs[i];
        }
        Core(getAddr("CORE")).grantRoles(_roles, _addrs);

        // Configuration
        ProfitManager pm = ProfitManager(getAddr(_mkt("_PROFIT_MANAGER")));
        CreditToken credit = CreditToken(getAddr(_mkt("_CREDIT")));
        pm.initializeReferences(
            getAddr(_mkt("_CREDIT")),
            getAddr("ERC20_GUILD")
        );
        pm.setProfitSharingConfig(
            SURPLUS_BUFFER_SPLIT,
            CREDIT_SPLIT,
            GUILD_SPLIT,
            OTHER_SPLIT,
            OTHER_ADDRESS
        );
        pm.setMinBorrow(MIN_BORROW);
        pm.setMaxTotalIssuance(MAX_TOTAL_ISSUANCE);
        credit.setMaxDelegates(3);
        credit.setDelegateLockupPeriod(1 hours);
        GuildToken(getAddr("ERC20_GUILD")).setCanExceedMaxGauges(
            getAddr(_mkt("_SGM")),
            true
        );
    }

    function run(address deployer) public pure virtual {}

    function teardown(address deployer) public pure virtual {}

    function validate(address deployer) public pure virtual {}
}
