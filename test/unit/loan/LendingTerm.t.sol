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
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

contract LendingTermUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    ProfitManager private profitManager;
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
    uint256 constant _MAX_DELAY_BETWEEN_PARTIAL_REPAY = 63115200; // 2 years
    uint256 constant _MIN_PARTIAL_REPAY_PERCENT = 0.2e18; // 20%
    uint256 constant _CALL_FEE = 0.05e18; // 5%
    uint256 constant _CALL_PERIOD = 1 hours;
    uint256 constant _HARDCAP = 20_000_000e18;
    uint256 constant _LTV_BUFFER = 0.20e18; // 20%

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        collateral = new MockERC20();
        credit = new CreditToken(address(core));
        guild = new GuildToken(address(core), address(profitManager), address(credit), _CYCLE_LENGTH, _FREEZE_PERIOD);
        rlcm = new RateLimitedCreditMinter(
            address(core), /*_core*/
            address(credit), /*_token*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        auctionHouse = new AuctionHouse(
            address(core),
            650,
            1800,
            0.1e18
        );
        term = new LendingTerm(
            address(core), /*_core*/
            address(profitManager), /*_profitManager*/
            address(guild), /*_guildToken*/
            address(auctionHouse), /*_auctionHouse*/
            address(rlcm), /*_creditMinter*/
            address(credit), /*_creditToken*/
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: _MAX_DELAY_BETWEEN_PARTIAL_REPAY,
                minPartialRepayPercent: _MIN_PARTIAL_REPAY_PERCENT,
                openingFee: 0,
                callFee: _CALL_FEE,
                callPeriod: _CALL_PERIOD,
                hardCap: _HARDCAP,
                ltvBuffer: _LTV_BUFFER
            })
        );
        profitManager.initializeReferences(address(credit), address(guild));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(address(term));
        guild.mint(address(this), _HARDCAP * 2);
        guild.incrementGauge(address(term), uint112(_HARDCAP));

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(collateral), "collateral");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(auctionHouse), "auctionHouse");
        vm.label(address(term), "term");
    }

    function testInitialState() public {
        assertEq(address(term.core()), address(core));
        assertEq(address(term.guildToken()), address(guild));
        assertEq(address(term.auctionHouse()), address(auctionHouse));
        assertEq(address(term.creditMinter()), address(rlcm));
        assertEq(address(term.creditToken()), address(credit));
        assertEq(address(term.collateralToken()), address(collateral));
        assertEq(term.maxDebtPerCollateralToken(), _CREDIT_PER_COLLATERAL_TOKEN);
        assertEq(term.interestRate(), _INTEREST_RATE);
        assertEq(term.maxDelayBetweenPartialRepay(), _MAX_DELAY_BETWEEN_PARTIAL_REPAY);
        assertEq(term.minPartialRepayPercent(), _MIN_PARTIAL_REPAY_PERCENT);
        assertEq(term.callFee(), _CALL_FEE);
        assertEq(term.callPeriod(), _CALL_PERIOD);
        assertEq(term.hardCap(), _HARDCAP);
        assertEq(term.ltvBuffer(), _LTV_BUFFER);
        assertEq(term.issuance(), 0);
        assertEq(term.getLoan(bytes32(0)).originationTime, 0);
        assertEq(term.getLoanDebt(bytes32(0)), 0);

        assertEq(collateral.totalSupply(), 0);
        assertEq(credit.totalSupply(), 0);
    }

    // borrow success
    function testBorrowSuccess() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // check loan creation
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.totalSupply(), borrowAmount);

        assertEq(term.getLoan(loanId).borrower, address(this));
        assertEq(term.getLoan(loanId).borrowAmount, borrowAmount);
        assertEq(term.getLoan(loanId).collateralAmount, collateralAmount);
        assertEq(term.getLoan(loanId).caller, address(0));
        assertEq(term.getLoan(loanId).callTime, 0);
        assertEq(term.getLoan(loanId).originationTime, block.timestamp);
        assertEq(term.getLoan(loanId).closeTime, 0);

        assertEq(term.issuance(), borrowAmount);
        assertEq(term.getLoanDebt(loanId), borrowAmount);

        // check interest accrued over time
        vm.warp(block.timestamp + term.YEAR());
        assertEq(term.getLoanDebt(loanId), borrowAmount * 110 / 100); // 10% APR
    }

    // borrow with opening fee success
    function testBorrowWithOpeningFeeSuccess() public {
        // create a similar term but with 5% opening fee
        LendingTerm term2 = new LendingTerm(
            address(core), /*_core*/
            address(profitManager), /*profitManager*/
            address(guild), /*_guildToken*/
            address(auctionHouse), /*_auctionHouse*/
            address(rlcm), /*_creditMinter*/
            address(credit), /*_creditToken*/
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: _MAX_DELAY_BETWEEN_PARTIAL_REPAY,
                minPartialRepayPercent: _MIN_PARTIAL_REPAY_PERCENT,
                openingFee: 0.05e18,
                callFee: _CALL_FEE,
                callPeriod: _CALL_PERIOD,
                hardCap: _HARDCAP,
                ltvBuffer: _LTV_BUFFER
            })
        );
        vm.label(address(term2), "term2");
        guild.addGauge(address(term2));
        guild.decrementGauge(address(term), uint112(_HARDCAP));
        guild.incrementGauge(address(term2), uint112(_HARDCAP));
        vm.startPrank(governor);
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term2));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term2));
        vm.stopPrank();

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term2), collateralAmount);
        credit.mint(address(this), 1_000e18);
        credit.approve(address(term2), 1_000e18);

        // borrow
        bytes32 loanId = term2.borrow(borrowAmount, collateralAmount);

        // check borrow success
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term2)), collateralAmount);
        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term2)), 0);
        assertEq(term2.getLoan(loanId).borrower, address(this));
    }

    // borrow fail because 0 collateral
    function testBorrowFailNoCollateral() public {
        uint256 borrowAmount = 1e18;
        uint256 collateralAmount = 0;
        vm.expectRevert("LendingTerm: cannot stake 0");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because not enough borrowed
    function testBorrowFailAmountTooSmall() public {
        uint256 borrowAmount = 1e18;
        uint256 collateralAmount = 1e18;
        vm.expectRevert("LendingTerm: borrow amount too low");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because 0 debt
    function testBorrowFailNoDebt() public {
        uint256 borrowAmount = 0;
        uint256 collateralAmount = 1e18;
        vm.expectRevert("LendingTerm: cannot borrow 0");
        term.borrow(borrowAmount, collateralAmount);
    } 

    // borrow fail because loan exists
    function testBorrowFailExists() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        assertEq(term.getLoan(loanId).originationTime, block.timestamp);

        // borrow again in same block (same loanId)
        vm.expectRevert("LendingTerm: loan exists");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because not enough collateral
    function testBorrowFailNotEnoughCollateral() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 9e18; // should be >= 10e18
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        vm.expectRevert("LendingTerm: not enough collateral");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because gauge killed
    function testBorrowFailGaugeKilled() public {
        // kill gauge
        guild.removeGauge(address(term));

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        vm.expectRevert("LendingTerm: debt ceiling reached");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because rate-limited minter role revoked
    function testBorrowFailRoleRevoked() public {
        // revoke role
        vm.prank(governor);
        core.revokeRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        vm.expectRevert("UNAUTHORIZED"); // failed because the terms can't mint CREDIT
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because debt ceiling is reached
    function testBorrowFailDebtCeilingReached() public {
        // add another gauge, equal voting weight for the 2nd gauge
        guild.addGauge(address(this));
        guild.mint(address(this), guild.getGaugeWeight(address(term)));
        guild.incrementGauge(address(this), uint112(guild.getGaugeWeight(address(term))));

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount * 2);
        collateral.approve(address(term), collateralAmount * 2);

        // first borrow works
        term.borrow(borrowAmount, collateralAmount);
        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);

        // second borrow fails because of relative debt ceilings
        vm.expectRevert("LendingTerm: debt ceiling reached");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because hardcap is reached
    function testBorrowFailHardcapReached() public {
        // prepare
        uint256 borrowAmount = _HARDCAP * 2;
        uint256 collateralAmount = borrowAmount * 2 * 1e18 / _CREDIT_PER_COLLATERAL_TOKEN;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        vm.expectRevert("LendingTerm: hardcap reached");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because ltv buffer is not respected
    function testBorrowFailLtvBuffer() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 11e18; // should be >= 12e18
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        vm.expectRevert("LendingTerm: not enough LTV buffer");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fail because paused
    function testBorrowFailPaused() public {
        // pause lending term
        vm.prank(guardian);
        term.pause();

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        vm.expectRevert("Pausable: paused");
        term.borrow(borrowAmount, collateralAmount);
    }

    // borrow fuzz for extreme borrowAmount & collateralAmount
    function testBorrowFuzz(uint256 borrowAmount, uint256 collateralAmount, uint256 interestTime) public {
        // fuzz conditions
        vm.assume(collateralAmount != 0);
        vm.assume(collateralAmount < 100_000_000_000_000e18); // irrealisticly large amount
        vm.assume(borrowAmount != 0);
        vm.assume(borrowAmount < 100_000_000_000_000e18); // irrealisticly large amount
        vm.assume(interestTime != 0);
        vm.assume(interestTime < 10 * 365 * 24 * 3600); // <= ~10 years

        // do not fuzz reverting conditions (below MIN_BORROW or under LTV)
        borrowAmount += term.MIN_BORROW();
        uint256 maxBorrow = collateralAmount * _CREDIT_PER_COLLATERAL_TOKEN * 1e18 / (1e18 * (1e18 + _LTV_BUFFER));
        vm.assume(borrowAmount <= maxBorrow);

        // prepare
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        vm.prank(governor);
        term.setHardCap(type(uint256).max);

        // borrow
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        assertEq(term.getLoanDebt(loanId), borrowAmount);

        // check interest accrued over time
        vm.warp(block.timestamp + interestTime);
        vm.roll(block.timestamp + interestTime / 13);
        uint256 interestAccrued = borrowAmount * _INTEREST_RATE * interestTime / term.YEAR() / 1e18;
        assertEq(term.getLoanDebt(loanId), borrowAmount + interestAccrued);
    }

    // addCollateral success
    function testAddCollateralSuccess() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        assertEq(term.getLoan(loanId).collateralAmount, collateralAmount);

        // addCollateral
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        term.addCollateral(loanId, collateralAmount);

        // checks
        assertEq(term.getLoan(loanId).collateralAmount, collateralAmount * 2);
        assertEq(collateral.balanceOf(address(term)), collateralAmount * 2);
        assertEq(collateral.balanceOf(address(this)), 0);
    }

    // addCollateral reverts
    function testAddCollateralFailures() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // repay
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 debt = term.getLoanDebt(loanId);
        credit.mint(address(this), debt - borrowAmount);
        credit.approve(address(term), debt);
        term.repay(loanId);

        // addCollateral failures
        vm.expectRevert("LendingTerm: cannot add 0");
        term.addCollateral(loanId, 0);
        vm.expectRevert("LendingTerm: loan closed");
        term.addCollateral(loanId, 123);
        vm.expectRevert("LendingTerm: loan not found");
        term.addCollateral(bytes32(0), 123);
    }

    // partialRepay success
    function testPartialRepaySuccess() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        assertEq(term.getLoan(loanId).collateralAmount, collateralAmount);

        // partialRepay
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        credit.mint(address(this), 11_000e18);
        credit.approve(address(term), 11_000e18);
        term.partialRepay(loanId, 11_000e18);

        // checks
        assertEq(term.getLoanDebt(loanId), 11_000e18);
        assertEq(term.getLoan(loanId).borrowAmount, 10_000e18);
    }

    // partialRepay reverts
    function testPartialRepayReverts() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // partialRepay
        vm.expectRevert("LendingTerm: loan opened in same block");
        term.partialRepay(loanId, 123);
        vm.expectRevert("LendingTerm: loan not found");
        term.partialRepay(bytes32(0), 123);
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        credit.mint(address(this), 11_000e18);
        credit.approve(address(term), 11_000e18);
        term.partialRepay(loanId, 11_000e18);
        assertEq(term.getLoanDebt(loanId), 11_000e18);
        credit.mint(address(this), 11_000e18);
        credit.approve(address(term), 11_000e18);
        vm.expectRevert("LendingTerm: full repayment");
        term.partialRepay(loanId, 11_000e18);
        vm.expectRevert("LendingTerm: repay too small");
        term.partialRepay(loanId, 1);
        vm.expectRevert("LendingTerm: repay below min");
        term.partialRepay(loanId, 2_100e18); // min would be 20% = 2_200e18
        term.repay(loanId);
        vm.expectRevert("LendingTerm: loan closed");
        term.partialRepay(loanId, 123);
    }

    // repay success
    function testRepaySuccess(uint256 time) public {
        vm.assume(time > 13);
        vm.assume(time < 10 * 365 * 24 * 3600);

        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // repay
        vm.warp(block.timestamp + time);
        vm.roll(block.number + 1);
        uint256 debt = term.getLoanDebt(loanId);
        credit.mint(address(this), debt - borrowAmount);
        credit.approve(address(term), debt);
        term.repay(loanId);

        assertEq(credit.totalSupply(), 0);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
    }

    // repay success after call deduce the call fee from debt
    function testRepaySuccessAfterCall(uint256 time) public {
        vm.assume(time > 13);
        vm.assume(time < 10 * 365 * 24 * 3600);

        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        credit.burn(borrowAmount);

        // call
        vm.warp(block.timestamp + time);
        vm.roll(block.number + 1);
        uint256 debt = term.getLoanDebt(loanId);
        uint256 callFee = term.getLoanCallFee(loanId);
        credit.mint(address(this), debt);
        credit.approve(address(term), callFee);
        term.call(loanId);

        // repay
        credit.approve(address(term), debt - callFee);
        term.repay(loanId);

        assertEq(credit.totalSupply(), 0);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
    }

    // repay fail because loan doesnt exist
    function testRepayFailLoanNotFound() public {
        vm.expectRevert("LendingTerm: loan not found");
        term.repay(bytes32(type(uint256).max));
    }

    // repay fail because loan created in same block
    function testRepayFailCreatedSameBlock() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // repay
        credit.approve(address(term), borrowAmount);
        vm.expectRevert("LendingTerm: loan opened in same block");
        term.repay(loanId);
    }

    // repay fail because loan is closed (1)
    function testRepayFailAlreadyClosed1() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // repay
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 debt = term.getLoanDebt(loanId);
        credit.mint(address(this), debt - borrowAmount);
        credit.approve(address(term), debt);
        term.repay(loanId);

        // repay again
        vm.expectRevert("LendingTerm: loan closed");
        term.repay(loanId);
    }

    // repay fail because loan is closed (2)
    function testRepayFailAlreadyClosed2() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // call
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        credit.mint(address(this), callFee);
        credit.approve(address(term), callFee);
        term.call(loanId);

        // seize
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);
        term.seize(loanId);

        // repay
        vm.expectRevert("LendingTerm: loan closed");
        term.repay(loanId);
    }

    // repay fail because rate-limited minter role revoked
    function testRepayFailRoleRevoked() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // revoke role so buffer of CREDIT cannot replenish
        vm.prank(governor);
        core.revokeRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));

        // repay
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 debt = term.getLoanDebt(loanId);
        credit.mint(address(this), debt - borrowAmount);
        credit.approve(address(term), debt);
        vm.expectRevert("UNAUTHORIZED");
        term.repay(loanId);
    }

    // call success
    function testCallSuccess() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // call
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        assertEq(term.getLoanCallFee(loanId), callFee);
        credit.approve(address(term), callFee);
        term.call(loanId);

        assertEq(term.getLoan(loanId).caller, address(this));
        assertEq(term.getLoan(loanId).callTime, block.timestamp);
        assertEq(credit.balanceOf(address(this)), borrowAmount - callFee);
        assertEq(credit.balanceOf(address(term)), callFee);
    }

    // callMany success
    function testCallManySuccess() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;

        // call
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        assertEq(term.getLoanCallFee(loanId), callFee);
        credit.approve(address(term), callFee);
        term.callMany(loanIds);

        assertEq(term.getLoan(loanId).caller, address(this));
        assertEq(term.getLoan(loanId).callTime, block.timestamp);
        assertEq(credit.balanceOf(address(this)), borrowAmount - callFee);
        assertEq(credit.balanceOf(address(term)), callFee);
    }

    // call fail because loan doesnt exist
    function testCallFailLoanNotFound() public {
        vm.expectRevert("LendingTerm: loan not found");
        term.call(bytes32(type(uint256).max));
    }

    // call fail because loan created in same block
    function testCallFailCreatedSameBlock() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // call
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        credit.approve(address(term), callFee);
        vm.expectRevert("LendingTerm: loan opened in same block");
        term.call(loanId);
    }

    // call fail because loan is already called
    function testCallFailAlreadyCalled() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // call
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        credit.approve(address(term), callFee);
        term.call(loanId);

        // call again
        vm.expectRevert("LendingTerm: loan called");
        term.call(loanId);
    }

    // call fail because loan is closed
    function testCallFailLoanClosed() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // repay
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 debt = term.getLoanDebt(loanId);
        credit.mint(address(this), debt - borrowAmount);
        credit.approve(address(term), debt);
        term.repay(loanId);

        // call
        vm.expectRevert("LendingTerm: loan closed");
        term.call(loanId);
    }

    // seize success
    function testSeizeSuccess() public {
        // prepare & borrow & call & wait call period
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        credit.approve(address(term), callFee);
        term.call(loanId);
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);

        // seize
        term.seize(loanId);

        // loan is closed
        assertEq(term.getLoan(loanId).closeTime, block.timestamp);
        assertEq(term.getLoanDebt(loanId), 0);
        assertEq(term.issuance(), borrowAmount);
        // borrower kept credit
        assertEq(credit.balanceOf(address(this)), borrowAmount - callFee);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // cannot set auctionHouse because an auction is in progress
        vm.prank(governor);
        vm.expectRevert("LendingTerm: auctions in progress");
        term.setAuctionHouse(address(this));
    }

    // seize success even without call, if loan missed a period partialRepay
    function testSeizeWithoutCallAfterPartialRepayDelay() public {
        // prepare & borrow & call & wait call period
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        assertEq(term.partialRepayDelayPassed(loanId), false);
        vm.warp(block.timestamp + term.YEAR() * 2 + 1);
        vm.roll(block.number + 1);
        assertEq(term.partialRepayDelayPassed(loanId), true);

        // seize
        term.seize(loanId);

        // loan is closed
        assertEq(term.getLoan(loanId).closeTime, block.timestamp);
        assertEq(term.getLoanDebt(loanId), 0);
        assertEq(term.issuance(), borrowAmount);
        // borrower kept credit
        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0); // no call fee collected
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
    }

    // seizeMany success
    function testSeizeManySuccess() public {
        // prepare & borrow & call & wait call period
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        credit.approve(address(term), callFee);
        term.call(loanId);
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);

        // seize
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;
        term.seizeMany(loanIds);

        // loan is closed
        assertEq(term.getLoan(loanId).closeTime, block.timestamp);
        assertEq(term.getLoanDebt(loanId), 0);
        assertEq(term.issuance(), borrowAmount);
        // borrower kept credit
        assertEq(credit.balanceOf(address(this)), borrowAmount - callFee);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
    }

    // seize fail because loan doesnt exist
    function testSeizeFailLoanNotFound() public {
        vm.expectRevert("LendingTerm: loan not found");
        term.seize(bytes32(type(uint256).max));
    }

    // seize fail because loan is closed (1)
    function testSeizeFailAlreadyClosed1() public {
        // prepare & borrow & call & wait call period
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        credit.approve(address(term), callFee);
        term.call(loanId);
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);

        // seize
        term.seize(loanId);

        // seize again
        vm.expectRevert("LendingTerm: loan closed");
        term.seize(loanId);
    }

    // seize fail because loan is closed (2)
    function testSeizeFailAlreadyClosed2() public {
        // prepare & borrow & repay
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        credit.mint(address(this), term.getLoanDebt(loanId) - borrowAmount);
        credit.approve(address(term), term.getLoanDebt(loanId));
        term.repay(loanId);

        // seize
        vm.expectRevert("LendingTerm: loan closed");
        term.seize(loanId);
    }

    // seize fail because loan is not called
    function testSeizeFailNotCalled() public {
        // prepare & borrow & call & wait call period
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        // seize
        vm.expectRevert("LendingTerm: loan not called");
        term.seize(loanId);
    }

    // seize fail because loan call period is not over
    function testSeizeFailCallPeriodNotOver() public {
        // prepare & borrow & call & wait call period
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 callFee = 1_000e18; // 5% of borrowAmount
        credit.approve(address(term), callFee);
        term.call(loanId);
        vm.warp(block.timestamp + term.callPeriod() / 2);
        vm.roll(block.number + 1);

        // seize
        vm.expectRevert("LendingTerm: call period in progress");
        term.seize(loanId);
    }

    // test governor-only setter for auctionHouse
    function testGovernorSetAuctionHouse() public {
        assertEq(term.auctionHouse(), address(auctionHouse));
        
        vm.prank(governor);
        term.setAuctionHouse(address(this));

        assertEq(term.auctionHouse(), address(this));

        vm.expectRevert("UNAUTHORIZED");
        term.setAuctionHouse(address(auctionHouse));
    }

    // test setter for hardCap
    function testSetHardCap() public {
        assertEq(term.hardCap(), _HARDCAP);
        
        vm.prank(governor);
        term.setHardCap(type(uint256).max);

        assertEq(term.hardCap(), type(uint256).max);

        vm.expectRevert("UNAUTHORIZED");
        term.setHardCap(12345);
    }

    // full flow test (borrow, repay)
    function testFlowBorrowRepay() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);

        // borrow
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        credit.mint(address(this), 2_000e18);

        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // repay
        credit.approve(address(term), 22_000e18);
        term.repay(loanId);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);
    }

    // full flow test (borrow, call, repay)
    function testFlowBorrowCallRepay() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);

        // borrow
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        credit.mint(address(this), 2_000e18);

        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // call
        uint256 callFee = 1_000e18;
        credit.approve(address(term), callFee);
        term.call(loanId);

        assertEq(credit.balanceOf(address(this)), 21_000e18);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // repay
        credit.approve(address(term), 21_000e18);
        term.repay(loanId);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);
    }

    // full flow test (borrow, call, seize, onBid with good debt)
    function testFlowBorrowCallSeizeOnBidGoodDebt() public {
        bytes32 loanId = keccak256(abi.encode(address(this), address(term), block.timestamp));
        assertEq(term.getLoanCallFee(loanId), 0);

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);

        // borrow
        bytes32 loanIdReturned = term.borrow(borrowAmount, collateralAmount);
        assertEq(loanId, loanIdReturned);

        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        credit.mint(address(this), 2_000e18);

        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // cannot seize because call isn't started
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;
        vm.expectRevert("LendingTerm: loan not called");
        term.seizeMany(loanIds);

        // call
        address caller = address(1000);
        uint256 callFee = 1_000e18;
        assertEq(term.getLoanCallFee(loanId), callFee);
        credit.mint(caller, callFee);
        vm.startPrank(caller);
        credit.approve(address(term), callFee);
        term.call(loanId);
        vm.stopPrank();
    
        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // cannot seize because call period isn't elapsed
        vm.expectRevert("LendingTerm: call period in progress");
        term.seizeMany(loanIds);

        // seize
        address bidder = address(101);
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);
        term.seize(loanId);

        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(credit.balanceOf(bidder), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
        assertEq(collateral.balanceOf(bidder), 0);

        assertEq(term.getLoanCallFee(loanId), 0); // /!\ not callFee because loan is closed now

        // auction bid
        credit.mint(bidder, 21_000e18);
        vm.prank(bidder);
        credit.approve(address(term), 21_000e18);
        vm.prank(address(auctionHouse));
        term.onBid(loanId, bidder, AuctionHouse.AuctionResult({
            collateralToBorrower: 3e18,
            collateralToCaller: 0,
            collateralToBidder: 12e18,
            creditFromBidder: 21_000e18,
            creditToCaller: 0,
            creditToBurn: 20_000e18,
            creditToProfit: 2_000e18,
            pnl: 2_000e18
        }));

        // check token movements
        assertEq(collateral.balanceOf(address(this)), 3e18);
        assertEq(collateral.balanceOf(caller), 0);
        assertEq(collateral.balanceOf(bidder), 12e18);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(caller), 0);
        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(bidder), 0);
    }
    
    // full flow test (borrow, call, seize, onBid with good debt but in danger zone)
    function testFlowBorrowCallSeizeOnBidGoodDangerousDebt() public {
        bytes32 loanId = keccak256(abi.encode(address(this), address(term), block.timestamp));
        assertEq(term.getLoanCallFee(loanId), 0);

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);

        // borrow
        bytes32 loanIdReturned = term.borrow(borrowAmount, collateralAmount);
        assertEq(loanId, loanIdReturned);

        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        credit.mint(address(this), 2_000e18);

        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // cannot seize because call isn't started
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;
        vm.expectRevert("LendingTerm: loan not called");
        term.seizeMany(loanIds);

        // call
        address caller = address(1000);
        uint256 callFee = 1_000e18;
        assertEq(term.getLoanCallFee(loanId), callFee);
        credit.mint(caller, callFee);
        vm.startPrank(caller);
        credit.approve(address(term), callFee);
        term.call(loanId);
        vm.stopPrank();
    
        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // cannot seize because call period isn't elapsed
        vm.expectRevert("LendingTerm: call period in progress");
        term.seizeMany(loanIds);

        // seize
        address bidder = address(101);
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);
        term.seize(loanId);

        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(credit.balanceOf(bidder), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
        assertEq(collateral.balanceOf(bidder), 0);

        assertEq(term.getLoanCallFee(loanId), 0); // /!\ not callFee because loan is closed now

        // auction bid
        credit.mint(bidder, 22_000e18);
        vm.prank(bidder);
        credit.approve(address(term), 22_000e18);
        vm.prank(address(auctionHouse));
        term.onBid(loanId, bidder, AuctionHouse.AuctionResult({
            collateralToBorrower: 2e18,
            collateralToCaller: 1e18,
            collateralToBidder: 12e18,
            creditFromBidder: 22_000e18,
            creditToCaller: 1_000e18,
            creditToBurn: 20_000e18,
            creditToProfit: 2_000e18,
            pnl: 2_000e18
        }));

        // check token movements
        assertEq(collateral.balanceOf(address(this)), 2e18);
        assertEq(collateral.balanceOf(caller), 1e18);
        assertEq(collateral.balanceOf(bidder), 12e18);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(caller), 1_000e18);
        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(bidder), 0);
    }

    // full flow test (borrow, call, seize, onBid with bad debt)
    function testFlowBorrowCallSeizeOnBidBadDebt() public {
        bytes32 loanId = keccak256(abi.encode(address(this), address(term), block.timestamp));
        assertEq(term.getLoanCallFee(loanId), 0);

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);

        // borrow
        bytes32 loanIdReturned = term.borrow(borrowAmount, collateralAmount);
        assertEq(loanId, loanIdReturned);

        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        credit.mint(address(this), 2_000e18);

        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // cannot seize because call isn't started
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;
        vm.expectRevert("LendingTerm: loan not called");
        term.seizeMany(loanIds);

        // call
        address caller = address(1000);
        uint256 callFee = 1_000e18;
        assertEq(term.getLoanCallFee(loanId), callFee);
        credit.mint(caller, callFee);
        vm.startPrank(caller);
        credit.approve(address(term), callFee);
        term.call(loanId);
        vm.stopPrank();
    
        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // cannot seize because call period isn't elapsed
        vm.expectRevert("LendingTerm: call period in progress");
        term.seizeMany(loanIds);

        // seize
        address bidder = address(101);
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);
        term.seize(loanId);

        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(credit.balanceOf(bidder), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
        assertEq(collateral.balanceOf(bidder), 0);

        assertEq(term.getLoanCallFee(loanId), 0); // /!\ not callFee because loan is closed now

        // auction bid
        credit.mint(bidder, 10_000e18);
        vm.prank(bidder);
        credit.approve(address(term), 10_000e18);
        vm.prank(address(auctionHouse));
        term.onBid(loanId, bidder, AuctionHouse.AuctionResult({
            collateralToBorrower: 0,
            collateralToCaller: 0,
            collateralToBidder: 15e18,
            creditFromBidder: 10_000e18,
            creditToCaller: 1_000e18,
            creditToBurn: 10_000e18,
            creditToProfit: 0,
            pnl: -10_000e18
        }));

        // check token movements
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(caller), 0);
        assertEq(collateral.balanceOf(bidder), 15e18);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(caller), 1_000e18);
        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(credit.balanceOf(bidder), 0);
    }

    // full flow test (borrow, forgive)
    function testFlowBorrowForgive() public {
        bytes32 loanId = keccak256(abi.encode(address(this), address(term), block.timestamp));
        assertEq(term.getLoanCallFee(loanId), 0);

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);

        // borrow
        bytes32 loanIdReturned = term.borrow(borrowAmount, collateralAmount);
        assertEq(loanId, loanIdReturned);

        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);

        assertEq(credit.balanceOf(address(this)), 20_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // test forgive reverts due to access control
        vm.expectRevert("UNAUTHORIZED");
        term.forgive(loanId);

        // forgive 
        vm.prank(governor);
        term.forgive(loanId);

        assertEq(term.getLoan(loanId).closeTime, block.timestamp);

        assertEq(credit.balanceOf(address(this)), 20_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(auctionHouse)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
        assertEq(collateral.balanceOf(address(auctionHouse)), 0);
    }

    // full flow test (borrow, call, forgive)
    function testFlowBorrowCallForgive() public {
        bytes32 loanId = keccak256(abi.encode(address(this), address(term), block.timestamp));
        assertEq(term.getLoanCallFee(loanId), 0);

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);

        // borrow
        bytes32 loanIdReturned = term.borrow(borrowAmount, collateralAmount);
        assertEq(loanId, loanIdReturned);

        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);

        assertEq(credit.balanceOf(address(this)), 20_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // call
        credit.mint(address(this), 1_000e18);
        credit.approve(address(term), 1_000e18);
        term.call(loanId);

        assertEq(credit.balanceOf(address(this)), 20_000e18);
        assertEq(credit.balanceOf(address(term)), 1_000e18);

        // forgive should reimburse the call fee
        vm.prank(governor);
        term.forgive(loanId);

        assertEq(term.getLoan(loanId).closeTime, block.timestamp);

        assertEq(credit.balanceOf(address(this)), 21_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(auctionHouse)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
        assertEq(collateral.balanceOf(address(auctionHouse)), 0);
    }

    // full flow test (borrow, set hardcap to 0, seize)
    function testFlowBorrowHardcap0Seize() public {
        bytes32 loanId = keccak256(abi.encode(address(this), address(term), block.timestamp));
        assertEq(term.getLoanCallFee(loanId), 0);

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);

        // borrow
        bytes32 loanIdReturned = term.borrow(borrowAmount, collateralAmount);
        assertEq(loanId, loanIdReturned);

        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);

        assertEq(credit.balanceOf(address(this)), 20_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // set hardcap to 0
        vm.prank(governor);
        term.setHardCap(0);

        // seize without call
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;
        term.seizeMany(loanIds);

        assertEq(credit.balanceOf(address(this)), 20_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
    }
}
