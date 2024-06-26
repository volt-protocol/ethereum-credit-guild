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

contract Arbitrum_4c_MarketWETH is Proposal {
    function name() public view virtual returns (string memory) {
        return "Arbitrum_4c_MarketWETH";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Arbitrum_4c_MarketWETH: wrong chain id"
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

    string internal constant PEG_TOKEN = "WETH";
    uint256 internal constant MARKET_ID = 3; // gauge type / market ID

    /// @notice guild mint ratio is 10e18, meaning for 1 credit 10 guild tokens are
    /// minted in SurplusGuildMinter
    uint256 internal constant GUILD_MINT_RATIO = 25_000e18;

    /// @notice ratio of guild tokens received per Credit earned in
    /// the Surplus Guild Minter
    uint256 internal constant GUILD_CREDIT_REWARD_RATIO = 50_000 * 1e18;

    /// @notice min borrow size in the market at launch
    uint256 internal constant MIN_BORROW = 0.15e18;

    /// @notice max total borrows in the market at launch
    uint256 internal constant MAX_TOTAL_ISSUANCE = 1_000 * 1e18;

    /// @notice buffer cap
    uint256 internal constant RLCM_BUFFER_CAP = 500 * 1e18; // 500
    /// @notice rate limit per second
    uint256 internal constant RLCM_BUFFER_REPLENISH = 0.00579e18; // ~500/day

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
    uint256 public constant DAO_VETO_CREDIT_QUORUM = 2_000e18;
    uint256 public constant ONBOARD_VETO_CREDIT_QUORUM = 200e18;

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
                string.concat("ECG ", PEG_TOKEN, "-", Strings.toString(MARKET_ID)),
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

            // ARB lending terms
            {
                uint48[4] memory borrowRatios = [
                    // 18 decimals -> no correction needed
                    0.00010e18,
                    0.00015e18,
                    0.00020e18,
                    0.00025e18
                ];
                uint56[5] memory interestRates = [0.01e18, 0.02e18, 0.03e18, 0.04e18, 0.05e18];
                string[20] memory labels = [
                    _mkt("_TERM_ARB_0.00010_01%"),
                    _mkt("_TERM_ARB_0.00010_02%"),
                    _mkt("_TERM_ARB_0.00010_03%"),
                    _mkt("_TERM_ARB_0.00010_04%"),
                    _mkt("_TERM_ARB_0.00010_05%"),
                    _mkt("_TERM_ARB_0.00015_01%"),
                    _mkt("_TERM_ARB_0.00015_02%"),
                    _mkt("_TERM_ARB_0.00015_03%"),
                    _mkt("_TERM_ARB_0.00015_04%"),
                    _mkt("_TERM_ARB_0.00015_05%"),
                    _mkt("_TERM_ARB_0.00020_01%"),
                    _mkt("_TERM_ARB_0.00020_02%"),
                    _mkt("_TERM_ARB_0.00020_03%"),
                    _mkt("_TERM_ARB_0.00020_04%"),
                    _mkt("_TERM_ARB_0.00020_05%"),
                    _mkt("_TERM_ARB_0.00025_01%"),
                    _mkt("_TERM_ARB_0.00025_02%"),
                    _mkt("_TERM_ARB_0.00025_03%"),
                    _mkt("_TERM_ARB_0.00025_04%"),
                    _mkt("_TERM_ARB_0.00025_05%")
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_12H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_ARB"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 800 * 1e18 + 1
                                    })
                                )
                            )
                        );
                    }
                }
            }

            // weETH lending terms
            {
                uint64[1] memory borrowRatios = [
                    // 18 decimals -> no correction needed
                    0.7e18
                ];
                uint64[3] memory interestRates = [0.08e18, 0.10e18, 0.12e18];
                string[3] memory labels = [
                    _mkt("_TERM_WEETH_0.7_08%"),
                    _mkt("_TERM_WEETH_0.7_10%"),
                    _mkt("_TERM_WEETH_0.7_12%")
                    
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_24H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_WEETH"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 100 * 1e18 + 1
                                    })
                                )
                            )
                        );
                    }
                }
            }

            // WBTC lending terms
            {
                uint104[3] memory borrowRatios = [
                    // 8 decimals -> 1e10 of correction needed
                    14e18 * 1e10,
                    15e18 * 1e10,
                    16e18 * 1e10
                ];
                uint56[3] memory interestRates = [0.03e18, 0.04e18, 0.05e18];
                string[9] memory labels = [
                    _mkt("_TERM_WBTC_14_03%"),
                    _mkt("_TERM_WBTC_14_04%"),
                    _mkt("_TERM_WBTC_14_05%"),
                    _mkt("_TERM_WBTC_15_03%"),
                    _mkt("_TERM_WBTC_15_04%"),
                    _mkt("_TERM_WBTC_15_05%"),
                    _mkt("_TERM_WBTC_16_03%"),
                    _mkt("_TERM_WBTC_16_04%"),
                    _mkt("_TERM_WBTC_16_05%")
                    
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_12H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_WBTC"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 1500 * 1e18 + 1
                                    })
                                )
                            )
                        );
                    }
                }
            }

            // PT-weETH-27JUN2024 lending terms
            {
                uint64[1] memory borrowRatios = [
                    // 18 decimals -> no correction needed
                    0.7e18
                ];
                uint64[7] memory interestRates = [
                    0.08e18,
                    0.10e18,
                    0.12e18,
                    0.14e18,
                    0.16e18,
                    0.18e18,
                    0.20e18
                ];
                string[7] memory labels = [
                    _mkt("_TERM_ERC20_PT_WEETH_27JUN2024_0.7_08%"),
                    _mkt("_TERM_ERC20_PT_WEETH_27JUN2024_0.7_10%"),
                    _mkt("_TERM_ERC20_PT_WEETH_27JUN2024_0.7_12%"),
                    _mkt("_TERM_ERC20_PT_WEETH_27JUN2024_0.7_14%"),
                    _mkt("_TERM_ERC20_PT_WEETH_27JUN2024_0.7_16%"),
                    _mkt("_TERM_ERC20_PT_WEETH_27JUN2024_0.7_18%"),
                    _mkt("_TERM_ERC20_PT_WEETH_27JUN2024_0.7_20%")
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_24H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_PT_WEETH_27JUN2024"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 100 * 1e18 + 1
                                    })
                                )
                            )
                        );
                    }
                }
            }

            // PT-rsETH-27JUN2024 lending terms
            {
                uint64[1] memory borrowRatios = [
                    // 18 decimals -> no correction needed
                    0.7e18
                ];
                uint64[7] memory interestRates = [
                    0.08e18,
                    0.10e18,
                    0.12e18,
                    0.14e18,
                    0.16e18,
                    0.18e18,
                    0.20e18
                ];
                string[7] memory labels = [
                    _mkt("_TERM_ERC20_PT_RSETH_27JUN2024_0.7_08%"),
                    _mkt("_TERM_ERC20_PT_RSETH_27JUN2024_0.7_10%"),
                    _mkt("_TERM_ERC20_PT_RSETH_27JUN2024_0.7_12%"),
                    _mkt("_TERM_ERC20_PT_RSETH_27JUN2024_0.7_14%"),
                    _mkt("_TERM_ERC20_PT_RSETH_27JUN2024_0.7_16%"),
                    _mkt("_TERM_ERC20_PT_RSETH_27JUN2024_0.7_18%"),
                    _mkt("_TERM_ERC20_PT_RSETH_27JUN2024_0.7_20%")
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_24H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_PT_RSETH_27JUN2024"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 100 * 1e18 + 1
                                    })
                                )
                            )
                        );
                    }
                }
            }

            // USDC lending terms
            {
                uint88[4] memory borrowRatios = [
                    // 6 decimals -> 1e12 of correction needed
                    0.000150e18 * 1e12,
                    0.000175e18 * 1e12,
                    0.000200e18 * 1e12,
                    0.000250e18 * 1e12
                ];
                uint56[3] memory interestRates = [0.03e18, 0.04e18, 0.05e18];
                string[12] memory labels = [
                    _mkt("_TERM_USDC_0.000150_03%"),
                    _mkt("_TERM_USDC_0.000150_04%"),
                    _mkt("_TERM_USDC_0.000150_05%"),
                    _mkt("_TERM_USDC_0.000175_03%"),
                    _mkt("_TERM_USDC_0.000175_04%"),
                    _mkt("_TERM_USDC_0.000175_05%"),
                    _mkt("_TERM_USDC_0.000200_03%"),
                    _mkt("_TERM_USDC_0.000200_04%"),
                    _mkt("_TERM_USDC_0.000200_05%"),
                    _mkt("_TERM_USDC_0.000250_03%"),
                    _mkt("_TERM_USDC_0.000250_04%"),
                    _mkt("_TERM_USDC_0.000250_05%")
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_12H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_USDC"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 1_500 * 1e18 + 1
                                    })
                                )
                            )
                        );
                    }
                }
            }

            // USDT lending terms
            {
                uint88[4] memory borrowRatios = [
                    // 6 decimals -> 1e12 of correction needed
                    0.000150e18 * 1e12,
                    0.000175e18 * 1e12,
                    0.000200e18 * 1e12,
                    0.000250e18 * 1e12
                ];
                uint56[3] memory interestRates = [0.03e18, 0.04e18, 0.05e18];
                string[12] memory labels = [
                    _mkt("_TERM_USDT_0.000150_03%"),
                    _mkt("_TERM_USDT_0.000150_04%"),
                    _mkt("_TERM_USDT_0.000150_05%"),
                    _mkt("_TERM_USDT_0.000175_03%"),
                    _mkt("_TERM_USDT_0.000175_04%"),
                    _mkt("_TERM_USDT_0.000175_05%"),
                    _mkt("_TERM_USDT_0.000200_03%"),
                    _mkt("_TERM_USDT_0.000200_04%"),
                    _mkt("_TERM_USDT_0.000200_05%"),
                    _mkt("_TERM_USDT_0.000250_03%"),
                    _mkt("_TERM_USDT_0.000250_04%"),
                    _mkt("_TERM_USDT_0.000250_05%")
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_12H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_USDT"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 1_500 * 1e18 + 1
                                    })
                                )
                            )
                        );
                    }
                }
            }

            // wstETH lending terms
            {
                uint64[1] memory borrowRatios = [
                    // 18 decimals -> no correction needed
                    0.95e18
                ];
                uint56[5] memory interestRates = [0.01e18, 0.02e18, 0.03e18, 0.04e18, 0.05e18];
                string[5] memory labels = [
                    _mkt("_TERM_WSTETH_0.95_01%"),
                    _mkt("_TERM_WSTETH_0.95_02%"),
                    _mkt("_TERM_WSTETH_0.95_03%"),
                    _mkt("_TERM_WSTETH_0.95_04%"),
                    _mkt("_TERM_WSTETH_0.95_05%")
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_24H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_WSTETH"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 500 * 1e18 + 1
                                    })
                                )
                            )
                        );
                    }
                }
            }

            // rETH lending terms
            {
                uint64[1] memory borrowRatios = [
                    // 18 decimals -> no correction needed
                    0.95e18
                ];
                uint56[5] memory interestRates = [0.01e18, 0.02e18, 0.03e18, 0.04e18, 0.05e18];
                string[5] memory labels = [
                    _mkt("_TERM_RETH_0.95_01%"),
                    _mkt("_TERM_RETH_0.95_02%"),
                    _mkt("_TERM_RETH_0.95_03%"),
                    _mkt("_TERM_RETH_0.95_04%"),
                    _mkt("_TERM_RETH_0.95_05%")
                ];
                for (uint256 i = 0; i < borrowRatios.length; i++) {
                    for (uint256 j = 0; j < interestRates.length; j++) {
                        setAddr(
                            labels[i * interestRates.length + j],
                            termFactory.createTerm(
                                MARKET_ID, // gauge type,
                                getAddr("LENDING_TERM_V1"), // implementation
                                getAddr("AUCTION_HOUSE_24H"), // auctionHouse
                                abi.encode(
                                    LendingTerm.LendingTermParams({
                                        collateralToken: getAddr("ERC20_RETH"),
                                        maxDebtPerCollateralToken: borrowRatios[
                                            i
                                        ],
                                        interestRate: interestRates[j],
                                        maxDelayBetweenPartialRepay: 0,
                                        minPartialRepayPercent: 0,
                                        openingFee: 0,
                                        hardCap: 400 * 1e18 + 1
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

        // grant roles in batch of 100 at most
        uint256 maxBatchSize = 100;
        uint256 nBatch = (n / maxBatchSize) + 1;
        for (uint256 batch = 0; batch < nBatch; batch++) {
            uint256 batchSize = n >= maxBatchSize ? maxBatchSize : n;
            bytes32[] memory _roles = new bytes32[](batchSize);
            address[] memory _addrs = new address[](batchSize);
            for (uint256 i = 0; i < batchSize; i++) {
                _roles[i] = roles[batch * maxBatchSize + i];
                _addrs[i] = addrs[batch * maxBatchSize + i];
            }
            Core(getAddr("CORE")).grantRoles(_roles, _addrs);
            n -= batchSize;
        }

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
        credit.setMaxDelegates(guild.maxDelegates());
        credit.setDelegateLockupPeriod(guild.delegateLockupPeriod());
        GuildToken(getAddr("ERC20_GUILD")).setCanExceedMaxGauges(
            getAddr(_mkt("_SGM")),
            true
        );
    }

    function run(address deployer) public pure virtual {}

    function teardown(address deployer) public pure virtual {}

    function validate(address deployer) public pure virtual {}
}
