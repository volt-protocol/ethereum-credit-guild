// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

contract AuctionHouseUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    address private borrower = address(3);
    address private caller = address(4);
    address private bidder = address(5);
    Core private core;
    ProfitManager private profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    SimplePSM private psm;
    RateLimitedMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTerm term;

    // AuctionHouse params
    uint256 constant _MIDPOINT = 650; // 10m50s
    uint256 constant _AUCTION_DURATION = 1800; // 30m

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        collateral = new MockERC20();
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(address(core), address(profitManager));
        rlcm = new RateLimitedMinter(
            address(core), /*_core*/
            address(credit), /*_token*/
            CoreRoles.RATE_LIMITED_CREDIT_MINTER, /*_role*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(collateral)
        );
        auctionHouse = new AuctionHouse(
            address(core),
            _MIDPOINT,
            _AUCTION_DURATION
        );
        term = LendingTerm(Clones.clone(address(new LendingTerm())));
        term.initialize(
            address(core),
            LendingTerm.LendingTermReferences({
                profitManager: address(profitManager),
                guildToken: address(guild),
                auctionHouse: address(auctionHouse),
                creditMinter: address(rlcm),
                creditToken: address(credit)
            }),
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: 2000e18, // 2000, same decimals
                interestRate: 0.10e18, // 10% APR
                maxDelayBetweenPartialRepay: 0,
                minPartialRepayPercent: 0,
                openingFee: 0,
                hardCap: 20_000_000e18 // 20M CREDIT
            })
        );
        profitManager.initializeReferences(address(credit), address(guild), address(psm));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(1, address(term));
        guild.mint(address(this), 1e18);
        guild.incrementGauge(address(term), 1e18);

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(collateral), "collateral");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(auctionHouse), "auctionHouse");
        vm.label(address(term), "term");
        vm.label(address(this), "test");
    }

    // constructor params & public state getters
    function testInitialState() public {
        assertEq(address(auctionHouse.core()), address(core));
        assertEq(auctionHouse.midPoint(), _MIDPOINT);
        assertEq(auctionHouse.auctionDuration(), _AUCTION_DURATION);
        assertEq(auctionHouse.nAuctionsInProgress(), 0);

        assertEq(collateral.totalSupply(), 0);
        assertEq(credit.totalSupply(), 0);
    }

    // 15e18 collateral
    // 20_000e18 initial borrow
    // warp 1 year, now 22_000e18 owed
    function _setupAndCallLoan() private returns (bytes32 loanId) {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(borrower), collateralAmount);
    
        // borrow
        vm.startPrank(borrower);
        collateral.approve(address(term), collateralAmount);
        loanId = term.borrow(borrowAmount, collateralAmount);
        vm.stopPrank();

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);

        // call
        guild.removeGauge(address(term));
        vm.startPrank(caller);
        term.call(loanId);
        vm.stopPrank();
    }

    // auction getter
    function testGetAuction() public {
        // initially, auction not found
        assertEq(auctionHouse.getAuction(bytes32(0)).startTime, 0);

        bytes32 loanId = _setupAndCallLoan();

        // auction started
        assertEq(auctionHouse.getAuction(loanId).startTime, block.timestamp);
        assertEq(auctionHouse.getAuction(loanId).endTime, 0);
        assertEq(auctionHouse.getAuction(loanId).lendingTerm, address(term));
        assertEq(auctionHouse.getAuction(loanId).collateralAmount, 15e18);
        assertEq(auctionHouse.getAuction(loanId).callDebt, 22_000e18);
    }

    // startAuction fail if not called by an active LendingTerm
    function testStartAuctionFailNotALendingTerm() public {
        bytes32 loanId = _setupAndCallLoan();

        vm.expectRevert("AuctionHouse: invalid caller");
        auctionHouse.startAuction(loanId, 22_000e18);
    }

    // startAuction fail if the loan is not closed in current block
    function testStartAuctionFailPreviouslyClosed() public {
        bytes32 loanId = _setupAndCallLoan();

        // the LendingTerm calls startAuction again in a later block
        // (this would only happen due to invalid logic in the LendingTerm)
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        vm.prank(address(term));
        vm.expectRevert("AuctionHouse: loan previously called");
        auctionHouse.startAuction(loanId, 22_000e18);
    }
    
    // startAuction fail if the auction already exists
    function testStartAuctionFailAlreadyAuctioned() public {
        bytes32 loanId = _setupAndCallLoan();

        // the LendingTerm calls startAuction again
        // (this would only happen due to invalid logic in the LendingTerm)
        vm.prank(address(term));
        vm.expectRevert("AuctionHouse: auction exists");
        auctionHouse.startAuction(loanId, 22_000e18);
    }

    // getBidDetail at various steps
    function testGetBidDetail() public {
        bytes32 loanId = _setupAndCallLoan();
        assertEq(auctionHouse.getAuction(loanId).collateralAmount, 15e18);
        assertEq(auctionHouse.getAuction(loanId).callDebt, 22_000e18);
        uint256 PHASE_1_DURATION = auctionHouse.midPoint();
        uint256 PHASE_2_DURATION = auctionHouse.auctionDuration() - auctionHouse.midPoint();

        // right at the start of auction
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 0);
            assertEq(creditAsked, 22_000e18);
        }

        // 10% of first phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 1.5e18);
            assertEq(creditAsked, 22_000e18);
        }

        // 50% of first phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION * 4 / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 7.5e18);
            assertEq(creditAsked, 22_000e18);
        }
    
        // 90% of first phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION * 4 / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 13.5e18);
            assertEq(creditAsked, 22_000e18);
        }

        // at midpoint
        // offer all collateral, ask all debt
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 15e18);
            assertEq(creditAsked, 22_000e18);
        }

        // 10% of second phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_2_DURATION / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 15e18);
            assertEq(creditAsked, 19_800e18);
        }

        // 50% of second phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_2_DURATION * 4 / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 15e18);
            assertEq(creditAsked, 11_000e18);
        }

        // 90% of second phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_2_DURATION * 4 / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 15e18);
            assertEq(creditAsked, 2_200e18);
        }

        // end of second phase (= end of auction)
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_2_DURATION / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 15e18);
            assertEq(creditAsked, 0);
        }

        // after end of second phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 123456);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 15e18);
            assertEq(creditAsked, 0);
        }
    }

    // getBidDetail fail if auction is not active
    function testGetBidDetailFailNotActive() public {
        vm.expectRevert("AuctionHouse: invalid auction");
        auctionHouse.getBidDetail(bytes32(0));
    }

    // getBidDetail fail if auction is ended
    function testGetBidDetailFailAuctionConcluded() public {
        bytes32 loanId = _setupAndCallLoan();
        ( , uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        credit.mint(address(this), creditAsked);
        credit.approve(address(term), creditAsked);
        auctionHouse.bid(loanId);

        vm.expectRevert("AuctionHouse: auction ended");
        auctionHouse.getBidDetail(loanId);
    }

    // bid fail if auction for this loan is not started
    function testBidFailNotActive() public {
        vm.expectRevert("AuctionHouse: invalid auction");
        auctionHouse.bid(bytes32(0));
    }

    // bid fail if auction has already concluded for this loan
    function testBidFailAuctionConcluded() public {
        bytes32 loanId = _setupAndCallLoan();
        ( , uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        credit.mint(address(this), creditAsked);
        credit.approve(address(term), creditAsked);
        auctionHouse.bid(loanId);

        // bid should close the loan
        assertEq(auctionHouse.getAuction(loanId).endTime, block.timestamp);

        vm.expectRevert("AuctionHouse: auction ended");
        auctionHouse.bid(loanId);
    }

    // bid fail if auction bid period is over, should use forgive instead
    function testBidFailBidPeriodElapsed() public {
        bytes32 loanId = _setupAndCallLoan();

        vm.warp(block.timestamp + auctionHouse.auctionDuration() + 1);
        ( , uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        assertEq(creditAsked, 0);
        assertEq(auctionHouse.getAuction(loanId).endTime, 0);

        vm.expectRevert("AuctionHouse: cannot bid 0");
        auctionHouse.bid(loanId);

        auctionHouse.forgive(loanId);
        assertEq(auctionHouse.getAuction(loanId).endTime, block.timestamp);
    }

    // bid success, that creates bad debt
    function testBidSuccessBadDebt() public {
        bytes32 loanId = _setupAndCallLoan();
        uint256 PHASE_1_DURATION = auctionHouse.midPoint();
        uint256 PHASE_2_DURATION = auctionHouse.auctionDuration() - auctionHouse.midPoint();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION + PHASE_2_DURATION / 2);

        // At this time, get full collateral, repay half debt
        (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        assertEq(collateralReceived, 15e18);
        assertEq(creditAsked, 11_000e18);

        // bid
        credit.mint(bidder, 11_000e18);
        vm.startPrank(bidder);
        credit.approve(address(term), 11_000e18);
        auctionHouse.bid(loanId);
        vm.stopPrank();

        // check token locations
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(bidder), 15e18);
        assertEq(collateral.totalSupply(), 15e18);
        assertEq(credit.balanceOf(bidder), 0);
        assertEq(credit.balanceOf(borrower), 20_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // check bad debt has been notified
        assertEq(guild.lastGaugeLoss(address(term)), block.timestamp);
    }

    // bid at various times (fuzz)
    function testBidSuccessFuzz(uint256 time) public {
        time = bound(time, 0, auctionHouse.auctionDuration() * 2);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + time);

        // trust getBidDetail's returned values
        bytes32 loanId = _setupAndCallLoan();
        (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        uint256 collateralReturnedToBorrower = 15e18 - collateralReceived;

        // check token locations
        assertEq(collateral.balanceOf(address(term)), 15e18);
        assertEq(collateral.totalSupply(), 15e18);
        assertEq(credit.balanceOf(borrower), 20_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // somebody bid in the auction
        if (creditAsked != 0) {
            credit.mint(bidder, creditAsked);
            vm.prank(bidder);
            credit.approve(address(term), creditAsked);
        }
        vm.prank(bidder);
        auctionHouse.bid(loanId);

        // bid should close the loan
        assertEq(auctionHouse.getAuction(loanId).endTime, block.timestamp);
        assertEq(term.getLoan(loanId).closeTime, block.timestamp);

        // check token locations
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(borrower), 20_000e18);
        assertEq(credit.totalSupply(), 20_000e18);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(bidder), collateralReceived);
        assertEq(collateral.balanceOf(borrower), collateralReturnedToBorrower);
        assertEq(collateral.totalSupply(), 15e18);

        // check if bad debt has been created, and if so, if it has been notified
        if (creditAsked < 20_000e18) {
            assertEq(guild.lastGaugeLoss(address(term)), block.timestamp);
        } else {
            assertEq(guild.lastGaugeLoss(address(term)), 0); // no loss
        }
    }

    // forgive a loan after the bid period is ended
    function testForgive() public {
        bytes32 loanId = _setupAndCallLoan();
        uint256 PHASE_1_DURATION = auctionHouse.midPoint();
        uint256 PHASE_2_DURATION = auctionHouse.auctionDuration() - auctionHouse.midPoint();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION + PHASE_2_DURATION / 2);

        // cannot forgive during auction
        vm.expectRevert("AuctionHouse: ongoing auction");
        auctionHouse.forgive(loanId);

        // At this time, get full collateral, repay 0 debt
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_2_DURATION / 2);
        (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        assertEq(collateralReceived, 15e18);
        assertEq(creditAsked, 0);

        // forgive
        vm.startPrank(bidder);
        auctionHouse.forgive(loanId);
        vm.stopPrank();

        // check token locations
        assertEq(collateral.balanceOf(address(term)), 15e18);
        assertEq(collateral.totalSupply(), 15e18);
        assertEq(credit.balanceOf(borrower), 20_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // check bad debt has been notified
        assertEq(guild.lastGaugeLoss(address(term)), block.timestamp);
    }
}
