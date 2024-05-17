// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {GuildVetoGovernor} from "@src/governance/GuildVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";

contract PostProposalCheckFixture is PostProposalCheck {
    // gauge type / market ID where to run the integration test suite
    uint256 internal constant MARKET_ID = 1;

    /// Users
    address public userOne = address(0x1111);
    address public userTwo = address(0x2222);
    address public userThree = address(0x3333);

    /// Team multisig
    address public teamMultisig;

    /// Core
    Core public core;

    /// Lending
    LendingTerm public term;
    LendingTermFactory public factory;
    LendingTermOnboarding public onboarder;
    LendingTermOffboarding public offboarder;

    MockERC20 public collateralToken;

    AuctionHouse public auctionHouse;

    ProfitManager public profitManager;

    SimplePSM public psm;

    /// Tokens
    GuildToken public guild;
    CreditToken public credit;
    ERC20 public usdc;

    /// Governor
    GuildGovernor public governor;
    GuildVetoGovernor public vetoGuildGovernor;
    GuildVetoGovernor public vetoCreditGovernor;
    GuildTimelockController public timelock;

    /// Minting
    RateLimitedMinter public rateLimitedCreditMinter;
    RateLimitedMinter public rateLimitedGuildMinter;
    SurplusGuildMinter public surplusGuildMinter;

    function _mkt(string memory x) private pure returns (string memory) {
        return string.concat(Strings.toString(MARKET_ID), x);
    }

    function setUp() public virtual override {
        super.setUp();

        /// --------------------------------------- ///
        /// ------------ address setup ------------ ///
        /// --------------------------------------- ///

        /// Team multisig
        teamMultisig = getAddr("TEAM_MULTISIG");

        /// core
        core = Core(getAddr("CORE"));

        usdc = ERC20(getAddr("ERC20_USDC"));
        guild = GuildToken(getAddr("ERC20_GUILD"));
        credit = CreditToken(getAddr(_mkt("_CREDIT")));

        /// rate limited minters
        rateLimitedCreditMinter = RateLimitedMinter(getAddr(_mkt("_RLCM")));
        rateLimitedGuildMinter = RateLimitedMinter(getAddr("RLGM"));
        surplusGuildMinter = SurplusGuildMinter(getAddr(_mkt("_SGM")));

        profitManager = ProfitManager(getAddr(_mkt("_PROFIT_MANAGER")));
        auctionHouse = AuctionHouse(getAddr("AUCTION_HOUSE_12H"));
        psm = SimplePSM(getAddr(_mkt("_PSM")));

        governor = GuildGovernor(payable(getAddr("DAO_GOVERNOR_GUILD")));
        vetoGuildGovernor = GuildVetoGovernor(
            payable(getAddr("ONBOARD_VETO_GUILD"))
        );
        vetoCreditGovernor = GuildVetoGovernor(
            payable(getAddr(_mkt("_ONBOARD_VETO_CREDIT")))
        );
        timelock = GuildTimelockController(payable(getAddr("DAO_TIMELOCK")));

        /// lending terms
        factory = LendingTermFactory(getAddr("LENDING_TERM_FACTORY"));
        onboarder = LendingTermOnboarding(
            payable(getAddr("ONBOARD_GOVERNOR_GUILD"))
        );
        offboarder = LendingTermOffboarding(getAddr("OFFBOARD_GOVERNOR_GUILD"));

        // create and onboard a new term for the integration tests
        collateralToken = new MockERC20();
        term = LendingTerm(
            factory.createTerm(
                MARKET_ID, // gauge type,
                getAddr("LENDING_TERM_V1"), // implementation
                getAddr("AUCTION_HOUSE_12H"), // auctionHouse
                abi.encode(
                    LendingTerm.LendingTermParams({
                        collateralToken: address(collateralToken),
                        maxDebtPerCollateralToken: 1e18,
                        interestRate: 0.04e18,
                        maxDelayBetweenPartialRepay: 0,
                        minPartialRepayPercent: 0,
                        openingFee: 0,
                        hardCap: 1e27
                    })
                )
            )
        );
        vm.startPrank(getAddr("ONBOARD_TIMELOCK"));
        guild.addGauge(MARKET_ID, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(term));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        vm.stopPrank();

        vm.label(userOne, "user one");
        vm.label(userTwo, "user two");
        vm.label(userThree, "user three");

        // Mint the first CREDIT tokens and enter rebase
        // Doing this with a non-dust balance ensures the share price internally
        // to the CreditToken has a reasonable size.
        {
            /// @notice USDC mint amount
            uint256 INITIAL_USDC_MINT_AMOUNT = 100 * 1e6;
            dealPegToken(userThree, INITIAL_USDC_MINT_AMOUNT);

            vm.startPrank(userThree);
            usdc.approve(address(psm), INITIAL_USDC_MINT_AMOUNT);
            psm.mint(userThree, INITIAL_USDC_MINT_AMOUNT);
            credit.enterRebase();
            vm.stopPrank();
        }
    }

    function dealCredit(address who, uint256 amount, bool adjust) public {
        uint256 balance = credit.balanceOf(who);
        if (adjust && balance < amount) {
            amount -= balance;
        }

        uint256 nPegTokens = psm.getRedeemAmountOut(amount) + 1;
        dealPegToken(address(this), nPegTokens);
        usdc.approve(address(psm), nPegTokens);
        psm.mint(who, nPegTokens);
    }

    function dealPegToken(address who, uint256 amount) public {
        vm.prank(0x8aFf09e2259cacbF4Fc4e3E53F3bf799EfEEab36); // USDC masterMinter
        (bool success1, ) = address(usdc).call(
            abi.encodeWithSignature(
                "configureMinter(address,uint256)",
                address(this),
                type(uint256).max
            )
        );
        (bool success2, ) = address(usdc).call(
            abi.encodeWithSignature("mint(address,uint256)", who, amount)
        );
        require(
            success1 && success2,
            "PostProposalCheckFixture: error in dealPegToken()"
        );
    }
}
