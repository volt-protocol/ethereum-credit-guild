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
import {NameLib as strings} from "@src/utils/NameLib.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {VoltTimelockController} from "@src/governance/VoltTimelockController.sol";
import {ProtocolConstants as constants} from "@src/utils/ProtocolConstants.sol";

contract PostProposalCheck is Test {
    Addresses addresses;
    uint256 preProposalsSnapshot;
    uint256 postProposalsSnapshot;

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

    function setUp() public virtual {
        preProposalsSnapshot = vm.snapshot();

        // Run all pending proposals before doing e2e tests
        TestProposals proposals = new TestProposals();
        proposals.setUp();
        proposals.setDebug(false);
        proposals.testProposals();
        addresses = proposals.addresses();

        postProposalsSnapshot = vm.snapshot();

        /// --------------------------------------- ///
        /// ------------ address setup ------------ ///
        /// --------------------------------------- ///

        /// core
        core = Core(addresses.mainnet(strings.CORE));

        usdc = ERC20(addresses.mainnet(strings.USDC));
        sdai = ERC20(addresses.mainnet(strings.SDAI));
        guild = GuildToken(addresses.mainnet(strings.GUILD_TOKEN));
        credit = CreditToken(addresses.mainnet(strings.CREDIT_TOKEN));

        /// rate limited minters
        rateLimitedCreditMinter = RateLimitedMinter(
            addresses.mainnet(strings.RATE_LIMITED_CREDIT_MINTER)
        );
        rateLimitedGuildMinter = RateLimitedMinter(
            addresses.mainnet(strings.RATE_LIMITED_GUILD_MINTER)
        );

        profitManager = ProfitManager(
            addresses.mainnet(strings.PROFIT_MANAGER)
        );
        auctionHouse = AuctionHouse(addresses.mainnet(strings.AUCTION_HOUSE));
        psm = SimplePSM(addresses.mainnet(strings.PSM_USDC));
        collateral = new MockERC20();

        governor = VoltGovernor(payable(addresses.mainnet(strings.GOVERNOR)));
        vetoGovernor = VoltVetoGovernor(
            payable(addresses.mainnet(strings.VETO_GOVERNOR))
        );
        timelock = VoltTimelockController(
            payable(addresses.mainnet(strings.TIMELOCK))
        );

        /// lending terms
        onboarder = LendingTermOnboarding(
            payable(addresses.mainnet(strings.LENDING_TERM_ONBOARDING))
        );
        offboarder = LendingTermOffboarding(
            addresses.mainnet(strings.LENDING_TERM_OFFBOARDING)
        );

        term = LendingTerm(
            onboarder.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: address(collateral),
                    maxDebtPerCollateralToken: constants.MAX_USDC_CREDIT_RATIO,
                    interestRate: constants.USDC_RATE,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: constants.USDC_CREDIT_HARDCAP
                })
            )
        );
    }
}
