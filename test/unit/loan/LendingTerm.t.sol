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

contract LendingTermUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
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
        guild = new GuildToken(address(core), _CYCLE_LENGTH, _FREEZE_PERIOD);
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
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(address(term));
        guild.mint(address(this), _HARDCAP * 2);
        guild.incrementGauge(address(term), uint112(_HARDCAP));
        vm.warp(block.timestamp + _CYCLE_LENGTH);

        // labels
        vm.label(address(core), "core");
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
        assertEq(term.creditPerCollateralToken(), _CREDIT_PER_COLLATERAL_TOKEN);
        assertEq(term.interestRate(), _INTEREST_RATE);
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

    // borrow fail because 0 collateral
    function testBorrowFailNoCollateral() public {
        uint256 borrowAmount = 1e18;
        uint256 collateralAmount = 0;
        vm.expectRevert("LendingTerm: cannot stake 0");
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
        vm.expectRevert("LendingTerm: terms unavailable");
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
        vm.warp(block.timestamp + _CYCLE_LENGTH);

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
        uint256 maxBorrow = collateralAmount * _CREDIT_PER_COLLATERAL_TOKEN * 1e18 / (1e18 * (1e18 + _LTV_BUFFER));
        vm.assume(borrowAmount <= maxBorrow);

        // prepare
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        vm.prank(governor);
        core.grantRole(CoreRoles.TERM_HARDCAP, address(this));
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
        vm.prank(guardian);
        core.guardianRevokeRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));

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
        assertEq(term.issuance(), 0);
        // borrower kept credit
        assertEq(credit.balanceOf(address(this)), borrowAmount - callFee);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(auctionHouse)), callFee);
        // collateral went to auctionHouse
        assertEq(collateral.balanceOf(address(auctionHouse)), collateralAmount);
        assertEq(collateral.balanceOf(address(term)), 0);
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
        core.grantRole(CoreRoles.TERM_HARDCAP, address(this));
        term.setHardCap(type(uint256).max);

        assertEq(term.hardCap(), type(uint256).max);

        vm.prank(governor);
        core.revokeRole(CoreRoles.TERM_HARDCAP, address(this));

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

    // full flow test (borrow, call, seize)
    function testFlowBorrowCallSeize() public {
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

        // call
        uint256 callFee = 1_000e18;
        assertEq(term.getLoanCallFee(loanId), callFee);
        credit.approve(address(term), callFee);
        term.call(loanId);
    
        assertEq(credit.balanceOf(address(this)), 21_000e18);
        assertEq(credit.balanceOf(address(term)), callFee);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // seize
        vm.warp(block.timestamp + term.callPeriod());
        vm.roll(block.number + 1);
        term.seize(loanId);

        assertEq(credit.balanceOf(address(this)), 21_000e18);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(auctionHouse)), callFee);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(collateral.balanceOf(address(auctionHouse)), collateralAmount);

        assertEq(term.getLoanCallFee(loanId), 0); // /!\ not callFee because loan is closed now
    }

    // TODO: test offboard + offboard flows
}
