// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

contract AuctionHouseUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    address private borrower = address(3);
    address private caller = address(4);
    address private bidder = address(5);
    Core private core;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    RateLimitedCreditMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTerm term;

    // GUILD params
    uint32 constant _CYCLE_LENGTH = 1 hours;
    uint32 constant _FREEZE_PERIOD = 10 minutes;

    // LendingTerm params
    uint256 constant _CREDIT_PER_COLLATERAL_TOKEN = 2000e18; // 2000, same decimals
    uint256 constant _INTEREST_RATE = 0.10e18; // 10% APR
    uint256 constant _CALL_FEE = 0.05e18; // 5%
    uint256 constant _CALL_PERIOD = 1 hours;
    uint256 constant _HARDCAP = 20_000_000e18;
    uint256 constant _LTV_BUFFER = 0.20e18; // 20%

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        collateral = new MockERC20();
        credit = new CreditToken(address(core));
        guild = new GuildToken(address(core), address(credit), _CYCLE_LENGTH, _FREEZE_PERIOD);
        rlcm = new RateLimitedCreditMinter(
            address(core), /*_core*/
            address(credit), /*_token*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        auctionHouse = new AuctionHouse(
            address(core),
            address(guild),
            address(rlcm),
            address(credit)
        );
        term = new LendingTerm(
            address(core), /*_core*/
            address(guild), /*_guildToken*/
            address(auctionHouse), /*_auctionHouse*/
            address(rlcm), /*_creditMinter*/
            address(credit), /*_creditToken*/
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                creditPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                callFee: _CALL_FEE,
                callPeriod: _CALL_PERIOD,
                hardCap: _HARDCAP,
                ltvBuffer: _LTV_BUFFER
            })
        );

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.TERM_OFFBOARD, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(auctionHouse));
        core.grantRole(CoreRoles.TERM_HARDCAP, address(auctionHouse));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(auctionHouse));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(address(term));
        guild.mint(address(this), 1e18);
        guild.incrementGauge(address(term), uint112(1e18));
        vm.warp(block.timestamp + _CYCLE_LENGTH);

        // labels
        vm.label(address(core), "core");
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
        assertEq(auctionHouse.MIDPOINT(), 650);
        assertEq(auctionHouse.AUCTION_DURATION(), 1800);
        assertEq(auctionHouse.guildToken(), address(guild));
        assertEq(auctionHouse.creditMinter(), address(rlcm));
        assertEq(auctionHouse.creditToken(), address(credit));

        assertEq(collateral.totalSupply(), 0);
        assertEq(credit.totalSupply(), 0);
    }

    function _setupLoan() private returns (bytes32 loanId) {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(borrower), collateralAmount);
    
        // borrow
        vm.startPrank(borrower);
        collateral.approve(address(term), collateralAmount);
        loanId = term.borrow(borrowAmount, collateralAmount);
        vm.stopPrank();
    }

    function _setupAndCallLoan() private returns (bytes32 loanId) {
        loanId = _setupLoan();

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR() - term.callPeriod());
        vm.roll(block.number + 1);

        // call
        credit.mint(caller, 1_000e18);
        vm.startPrank(caller);
        credit.approve(address(term), 1_000e18);
        term.call(loanId);
        vm.stopPrank();
    }

    function _setupLoanAndSeizeCollateral() private returns (bytes32 loanId) {
        loanId = _setupAndCallLoan();

        // seize
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);
        term.seize(loanId);
    }

    function _setupLoanAndOffboard() private returns (bytes32 loanId) {
        loanId = _setupLoan();

        // 1 year later, interest accrued
        // offboard term
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;
        bool[] memory skipCall = new bool[](1);
        skipCall[0] = true;
        term.seize(loanIds, skipCall);
    }

    // auction getter
    function testGetAuction() public {
        // initially, auction not found
        assertEq(auctionHouse.getAuction(bytes32(0)).startTime, 0);

        bytes32 loanId = _setupLoanAndSeizeCollateral();

        // auction started
        assertEq(auctionHouse.getAuction(loanId).startTime, block.timestamp);
        assertEq(auctionHouse.getAuction(loanId).endTime, 0);
        assertEq(auctionHouse.getAuction(loanId).lendingTerm, address(term));
        assertEq(auctionHouse.getAuction(loanId).caller, caller);
        assertEq(auctionHouse.getAuction(loanId).borrower, borrower);
        assertEq(auctionHouse.getAuction(loanId).collateralToken, address(collateral));
        assertEq(auctionHouse.getAuction(loanId).collateralAmount, 15e18);
        assertEq(auctionHouse.getAuction(loanId).debtAmount, 22_000e18);
        assertEq(auctionHouse.getAuction(loanId).ltvBuffer, _LTV_BUFFER);
        assertEq(auctionHouse.getAuction(loanId).callFeeAmount, 1000e18);
    }

    // startAuction fail if not called by an active LendingTerm
    function testStartAuctionFailNotALendingTerm() public {
        bytes32 loanId = _setupLoanAndSeizeCollateral();

        vm.expectRevert("AuctionHouse: invalid gauge");
        auctionHouse.startAuction(loanId, 22_000e18, true);
    }

    // startAuction fail if the loan is not closed in current block
    function testStartAuctionFailPreviouslyClosed() public {
        bytes32 loanId = _setupLoanAndSeizeCollateral();

        // the LendingTerm calls startAuction again in a later block
        // (this would only happen due to invalid logic in the LendingTerm)
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        vm.prank(address(term));
        vm.expectRevert("AuctionHouse: loan previously closed");
        auctionHouse.startAuction(loanId, 22_000e18, true);
    }
    
    // startAuction fail if the auction already exists
    function testStartAuctionFailAlreadyAuctioned() public {
        bytes32 loanId = _setupLoanAndSeizeCollateral();

        // the LendingTerm calls startAuction again
        // (this would only happen due to invalid logic in the LendingTerm)
        vm.prank(address(term));
        vm.expectRevert("AuctionHouse: auction exists");
        auctionHouse.startAuction(loanId, 22_000e18, true);
    }

    // startAuction fail if debt to recover < borrow amount
    function testStartAuctionFailDebtUnderBorrow() public {
        bytes32 loanId = _setupLoanAndSeizeCollateral();

        // the LendingTerm calls startAuction (again) with a debt amount under borrow amount
        // (this would only happen due to invalid logic in the LendingTerm)
        vm.prank(address(term));
        vm.expectRevert("AuctionHouse: negative interest");
        auctionHouse.startAuction(loanId, 19_000e18, true);
    }

    // startAuction fail if no collateral is available on LendingTerm
    function testStartAuctionFailNoCollateralLeft() public {
        bytes32 loanId = _setupAndCallLoan();

        // the LendingTerm calls startAuction during seize() but the collateral
        // is not available on the LendingTerm anymore.
        // (this would only happen due to invalid logic in the LendingTerm)
        vm.startPrank(address(term));
        collateral.transfer(governor, collateral.balanceOf(address(term)));
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        term.seize(loanId);
        vm.stopPrank();
    }

    // getBidDetail at various steps
    function testGetBidDetailWithDiscount() public {
        bytes32 loanId = _setupLoanAndSeizeCollateral();
        assertEq(auctionHouse.getAuction(loanId).collateralAmount, 15e18);
        assertEq(auctionHouse.getAuction(loanId).debtAmount, 22_000e18);
        uint256 PHASE_1_DURATION = auctionHouse.MIDPOINT();
        uint256 PHASE_2_DURATION = auctionHouse.AUCTION_DURATION() - auctionHouse.MIDPOINT();

        // right at the start of auction
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 0);
            assertEq(creditAsked, 21_000e18);
        }

        // 10% of first phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 1.5e18);
            assertEq(creditAsked, 21_000e18);
        }

        // 50% of first phase
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION * 4 / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 7.5e18);
            assertEq(creditAsked, 21_000e18);
        }
    
        // 90% of first phase
        // now it also asks for the call fee because we're under LTV buffer
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION * 4 / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 13.5e18);
            assertEq(creditAsked, 22_000e18);
        }

        // at midpoint
        // offer all collateral, ask all debt (including call fee)
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

    // getBidDetail at various steps
    function testGetBidDetailWithoutDiscount() public {
        bytes32 loanId = _setupLoanAndOffboard();
        assertEq(auctionHouse.getAuction(loanId).collateralAmount, 15e18);
        assertEq(auctionHouse.getAuction(loanId).debtAmount, 22_000e18);
        uint256 PHASE_1_DURATION = auctionHouse.MIDPOINT();
        uint256 PHASE_2_DURATION = auctionHouse.AUCTION_DURATION() - auctionHouse.MIDPOINT();

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
        // now it also asks for the call fee because we're under LTV buffer
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION * 4 / 10);
        {
            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
            assertEq(collateralReceived, 13.5e18);
            assertEq(creditAsked, 22_000e18);
        }

        // at midpoint
        // offer all collateral, ask all debt (including call fee)
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
        bytes32 loanId = _setupLoanAndSeizeCollateral();
        ( , uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        credit.mint(address(this), creditAsked);
        credit.approve(address(auctionHouse), creditAsked);
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
        bytes32 loanId = _setupLoanAndSeizeCollateral();
        ( , uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        credit.mint(address(this), creditAsked);
        credit.approve(address(auctionHouse), creditAsked);
        auctionHouse.bid(loanId);

        // bid should close the loan
        assertEq(auctionHouse.getAuction(loanId).endTime, block.timestamp);

        vm.expectRevert("AuctionHouse: auction ended");
        auctionHouse.bid(loanId);
    }

    // bid success, that creates bad debt
    function testBidSuccessBadDebt() public {
        bytes32 loanId = _setupLoanAndSeizeCollateral();
        uint256 PHASE_1_DURATION = auctionHouse.MIDPOINT();
        uint256 PHASE_2_DURATION = auctionHouse.AUCTION_DURATION() - auctionHouse.MIDPOINT();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PHASE_1_DURATION + PHASE_2_DURATION / 2);

        // At this time, get full collateral, repay half debt
        (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        assertEq(collateralReceived, 15e18);
        assertEq(creditAsked, 11_000e18);

        // bid
        credit.mint(bidder, 11_000e18);
        vm.startPrank(bidder);
        credit.approve(address(auctionHouse), 11_000e18);
        auctionHouse.bid(loanId);
        vm.stopPrank();

        // check token locations
        assertEq(collateral.balanceOf(address(auctionHouse)), 0);
        assertEq(collateral.balanceOf(bidder), 15e18);
        assertEq(collateral.totalSupply(), 15e18);
        assertEq(credit.balanceOf(borrower), 20_000e18);
        assertEq(credit.balanceOf(caller), 1_000e18);
        assertEq(credit.totalSupply(), 21_000e18);

        // check bad debt has been notified
        assertEq(guild.lastGaugeLoss(address(term)), block.timestamp);
    }

    // bid at various times (fuzz)
    function testBidSuccessFuzz(uint256 time) public {
        vm.assume(time < auctionHouse.AUCTION_DURATION() * 2);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + time);

        // trust getBidDetail's returned values
        bytes32 loanId = _setupLoanAndSeizeCollateral();
        (uint256 collateralReceived, uint256 creditAsked) = auctionHouse.getBidDetail(loanId);
        uint256 collateralReturnedToBorrower = 15e18 - collateralReceived;
        uint256 minCollateralForASafeLoan = 3e18;

        // check token locations
        assertEq(collateral.balanceOf(address(auctionHouse)), 15e18);
        assertEq(collateral.totalSupply(), 15e18);
        assertEq(credit.balanceOf(address(auctionHouse)), 1_000e18); // call fee
        assertEq(credit.balanceOf(borrower), 20_000e18);
        assertEq(credit.totalSupply(), 21_000e18);

        // somebody bid in the auction
        if (creditAsked != 0) {
            credit.mint(bidder, creditAsked);
            vm.prank(bidder);
            credit.approve(address(auctionHouse), creditAsked);
        }
        vm.prank(bidder);
        auctionHouse.bid(loanId);

        // bid should close the loan
        assertEq(auctionHouse.getAuction(loanId).endTime, block.timestamp);

        // check token locations
        assertEq(credit.balanceOf(address(auctionHouse)), 0);
        assertEq(credit.balanceOf(borrower), 20_000e18);
        assertEq(credit.totalSupply(), 20_000e18);
        assertEq(collateral.balanceOf(address(auctionHouse)), 0);
        assertEq(collateral.balanceOf(borrower), collateralReturnedToBorrower);
        assertEq(collateral.balanceOf(bidder), collateralReceived);
        assertEq(collateral.totalSupply(), 15e18);
        // loan was safe
        if (collateralReturnedToBorrower > minCollateralForASafeLoan) {
            // no new CREDIT minted to reimburse the call fee,
            // because the loan was safe
            assertEq(credit.totalSupply(), 20_000e18);
            // all CREDIT minted by bidder to get collateral has been burnt, as well as the call fee
            assertEq(credit.balanceOf(borrower), 20_000e18);
            assertEq(credit.totalSupply(), 20_000e18);
        }
        // loan was unsafe of insolvent
        else {
            assertEq(credit.balanceOf(borrower), 20_000e18);
            assertEq(credit.balanceOf(caller), 1_000e18);
            assertEq(credit.totalSupply(), 21_000e18);

            // check if bad debt has been created, and if so, if it has been notified
            if (creditAsked < 22_000e18) {
                assertEq(guild.lastGaugeLoss(address(term)), block.timestamp);
            } else {
                assertEq(guild.lastGaugeLoss(address(term)), 0); // no loss
            }
        }
    }
}