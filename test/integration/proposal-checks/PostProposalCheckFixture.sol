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

    /// @notice for each SDAI collateral, up to 1 credit can be borrowed
    uint256 internal constant MAX_SDAI_CREDIT_RATIO = 1e18;

    /// @notice credit hardcap at launch
    uint256 internal constant CREDIT_HARDCAP = 2_000_000 * 1e18;

    /// @notice SDAI credit hardcap at launch
    uint256 internal constant SDAI_CREDIT_HARDCAP = 2_000_000 * 1e18;

    /// @notice USDC mint amount
    uint256 internal constant INITIAL_USDC_MINT_AMOUNT = 100 * 1e6;

    /// ------------------------------------------------------------------------
    /// @notice Interest Rate Parameters
    /// ------------------------------------------------------------------------

    /// @notice rate to borrow against SDAI collateral
    uint256 internal constant SDAI_RATE = 0.04e18;

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

        profitManager = ProfitManager(addresses.mainnet("PROFIT_MANAGER"));
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

        vm.label(userOne, "user one");
        vm.label(userTwo, "user two");
        vm.label(userThree, "user three");

        // Mint the first CREDIT tokens and enter rebase
        // Doing this with a non-dust balance ensures the share price internally
        // to the CreditToken has a reasonable size.
        {
            deal(address(usdc), userThree, INITIAL_USDC_MINT_AMOUNT);

            vm.startPrank(userThree);
            usdc.approve(address(psm), INITIAL_USDC_MINT_AMOUNT);
            psm.mint(userThree, INITIAL_USDC_MINT_AMOUNT);
            credit.enterRebase();
            vm.stopPrank();
        }
    }
}
