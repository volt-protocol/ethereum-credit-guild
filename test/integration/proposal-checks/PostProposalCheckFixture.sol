// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Test} from "@forge-std/Test.sol";

import {Core} from "@src/core/Core.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {Addresses} from "@test/proposals/Addresses.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {VoltGovernor} from "@src/governance/VoltGovernor.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {TestProposals} from "@test/proposals/TestProposals.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {VoltVetoGovernor} from "@src/governance/VoltVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {PostProposalCheck} from "@test/integration/proposal-checks/PostProposalCheck.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {VoltTimelockController} from "@src/governance/VoltTimelockController.sol";

contract PostProposalCheckFixture is PostProposalCheck {
    /// Users
    address public userOne = address(0x1111);
    address public userTwo = address(0x2222);
    address public userThree = address(0x3333);

    /// Core
    Core public core;

    /// Lending
    LendingTerm public term;
    LendingTermOnboarding public onboarder;
    LendingTermOffboarding public offboarder;

    MockERC20 public collateral;

    AuctionHouse public auctionHouse;

    ProfitManager public profitManager;

    SimplePSM public psm;

    /// Tokens
    GuildToken public guild;
    CreditToken public credit;
    ERC20 public usdc;
    ERC20 public sdai;

    /// Governor
    VoltGovernor public governor;
    VoltVetoGovernor public vetoGovernor;
    VoltTimelockController public timelock;

    /// Minting
    RateLimitedMinter public rateLimitedCreditMinter;
    RateLimitedMinter public rateLimitedGuildMinter;
    SurplusGuildMinter public surplusGuildMinter;


    /// @notice maximum guild supply is 1b tokens, however this number can change
    /// later if new tokens are minted
    uint256 internal constant GUILD_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice guild mint ratio is 5e18, meaning for 1 credit 5 guild tokens are
    /// minted in SurplusGuildMinter
    uint256 internal constant GUILD_MINT_RATIO = 5e18;

    /// @notice ratio of guild tokens received per Credit earned in
    /// the Surplus Guild Minter
    uint256 internal constant GUILD_CREDIT_REWARD_RATIO = 0.1e18;

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


    function setUp() public virtual override {
        super.setUp();

        /// --------------------------------------- ///
        /// ------------ address setup ------------ ///
        /// --------------------------------------- ///

        /// core
        core = Core(addresses.mainnet("CORE"));

        usdc = ERC20(addresses.mainnet("ERC20_USDC"));
        sdai = ERC20(addresses.mainnet("ERC20_SDAI"));
        guild = GuildToken(addresses.mainnet("GUILD_TOKEN"));
        credit = CreditToken(addresses.mainnet("CREDIT_TOKEN"));

        /// rate limited minters
        rateLimitedCreditMinter = RateLimitedMinter(
            addresses.mainnet("RATE_LIMITED_CREDIT_MINTER")
        );
        rateLimitedGuildMinter = RateLimitedMinter(
            addresses.mainnet("RATE_LIMITED_GUILD_MINTER")
        );
        surplusGuildMinter = SurplusGuildMinter(
            addresses.mainnet("SURPLUS_GUILD_MINTER")
        );

        profitManager = ProfitManager(
            addresses.mainnet("PROFIT_MANAGER")
        );
        auctionHouse = AuctionHouse(addresses.mainnet("AUCTION_HOUSE"));
        psm = SimplePSM(addresses.mainnet("PSM_USDC"));
        collateral = new MockERC20();

        governor = VoltGovernor(payable(addresses.mainnet("GOVERNOR")));
        vetoGovernor = VoltVetoGovernor(
            payable(addresses.mainnet("VETO_GOVERNOR"))
        );
        timelock = VoltTimelockController(
            payable(addresses.mainnet("TIMELOCK"))
        );

        /// lending terms
        onboarder = LendingTermOnboarding(
            payable(addresses.mainnet("LENDING_TERM_ONBOARDING"))
        );
        offboarder = LendingTermOffboarding(
            addresses.mainnet("LENDING_TERM_OFFBOARDING")
        );

        term = LendingTerm(addresses.mainnet("TERM_SDAI_1"));
    }
}
