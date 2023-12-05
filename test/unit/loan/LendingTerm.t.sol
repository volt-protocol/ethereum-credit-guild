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

contract LendingTermUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    ProfitManager private profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    SimplePSM private psm;
    RateLimitedMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTerm term;

    // LendingTerm params
    uint256 constant _CREDIT_PER_COLLATERAL_TOKEN = 2000e18; // 2000, same decimals
    uint256 constant _INTEREST_RATE = 0.10e18; // 10% APR
    uint256 constant _MAX_DELAY_BETWEEN_PARTIAL_REPAY = 63115200; // 2 years
    uint256 constant _MIN_PARTIAL_REPAY_PERCENT = 0.2e18; // 20%
    uint256 constant _HARDCAP = 20_000_000e18;

    uint256 public issuance = 0;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        collateral = new MockERC20();
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(
            address(core),
            address(profitManager)
        );
        rlcm = new RateLimitedMinter(
            address(core) /*_core*/,
            address(credit) /*_token*/,
            CoreRoles.RATE_LIMITED_CREDIT_MINTER /*_role*/,
            type(uint256).max /*_maxRateLimitPerSecond*/,
            type(uint128).max /*_rateLimitPerSecond*/,
            type(uint128).max /*_bufferCap*/
        );
        auctionHouse = new AuctionHouse(address(core), 650, 1800);
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
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: _MAX_DELAY_BETWEEN_PARTIAL_REPAY,
                minPartialRepayPercent: _MIN_PARTIAL_REPAY_PERCENT,
                openingFee: 0,
                hardCap: _HARDCAP
            })
        );
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(collateral)
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
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(1, address(term));
        guild.mint(address(this), _HARDCAP * 2);
        guild.incrementGauge(address(term), _HARDCAP);

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

    function testInitialState() public {
        assertEq(address(term.core()), address(core));

        LendingTerm.LendingTermReferences memory refs = term.getReferences();
        assertEq(refs.guildToken, address(guild));
        assertEq(refs.auctionHouse, address(auctionHouse));
        assertEq(refs.creditMinter, address(rlcm));
        assertEq(refs.creditToken, address(credit));

        LendingTerm.LendingTermParams memory params = term.getParameters();
        assertEq(params.collateralToken, address(collateral));
        assertEq(
            params.maxDebtPerCollateralToken,
            _CREDIT_PER_COLLATERAL_TOKEN
        );
        assertEq(params.interestRate, _INTEREST_RATE);
        assertEq(
            params.maxDelayBetweenPartialRepay,
            _MAX_DELAY_BETWEEN_PARTIAL_REPAY
        );
        assertEq(params.minPartialRepayPercent, _MIN_PARTIAL_REPAY_PERCENT);
        assertEq(params.hardCap, _HARDCAP);

        assertEq(term.issuance(), 0);
        assertEq(term.getLoan(bytes32(0)).borrowTime, 0);
        assertEq(term.getLoanDebt(bytes32(0)), 0);

        assertEq(collateral.totalSupply(), 0);
        assertEq(credit.totalSupply(), 0);
    }

    // initialization test
    function testInitialize() public {
        LendingTerm implementation = new LendingTerm();
        LendingTerm clone = LendingTerm(Clones.clone(address(implementation)));

        // cannot initialize implementation
        vm.expectRevert();
        implementation.initialize(
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
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: _MAX_DELAY_BETWEEN_PARTIAL_REPAY,
                minPartialRepayPercent: _MIN_PARTIAL_REPAY_PERCENT,
                openingFee: 0.05e18,
                hardCap: _HARDCAP
            })
        );

        // can initialize clone
        clone.initialize(
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
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: _MAX_DELAY_BETWEEN_PARTIAL_REPAY,
                minPartialRepayPercent: _MIN_PARTIAL_REPAY_PERCENT,
                openingFee: 0.05e18,
                hardCap: _HARDCAP
            })
        );

        // cannot initialize clone twice
        vm.expectRevert();
        clone.initialize(
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
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: _MAX_DELAY_BETWEEN_PARTIAL_REPAY,
                minPartialRepayPercent: _MIN_PARTIAL_REPAY_PERCENT,
                openingFee: 0.05e18,
                hardCap: _HARDCAP
            })
        );
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
        assertEq(term.getLoan(loanId).borrowTime, block.timestamp);
        assertEq(term.getLoan(loanId).borrowAmount, borrowAmount);
        assertEq(term.getLoan(loanId).collateralAmount, collateralAmount);
        assertEq(term.getLoan(loanId).caller, address(0));
        assertEq(term.getLoan(loanId).callTime, 0);
        assertEq(term.getLoan(loanId).closeTime, 0);

        assertEq(term.issuance(), borrowAmount);
        assertEq(term.getLoanDebt(loanId), borrowAmount);

        // check interest accrued over time
        vm.warp(block.timestamp + term.YEAR());
        assertEq(term.getLoanDebt(loanId), (borrowAmount * 110) / 100); // 10% APR
    }

    // borrow with opening fee success
    function testBorrowWithOpeningFeeSuccess() public {
        // create a similar term but with 5% opening fee
        LendingTerm term2 = LendingTerm(
            Clones.clone(address(new LendingTerm()))
        );
        term2.initialize(
            address(core),
            term.getReferences(),
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: _MAX_DELAY_BETWEEN_PARTIAL_REPAY,
                minPartialRepayPercent: _MIN_PARTIAL_REPAY_PERCENT,
                openingFee: 0.05e18,
                hardCap: _HARDCAP
            })
        );
        vm.label(address(term2), "term2");
        guild.addGauge(1, address(term2));
        guild.decrementGauge(address(term), _HARDCAP);
        guild.incrementGauge(address(term2), _HARDCAP);
        vm.startPrank(governor);
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term2));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term2));
        vm.stopPrank();

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term2), collateralAmount);

        // borrow
        bytes32 loanId = term2.borrow(borrowAmount, collateralAmount);

        // check borrow success
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term2)), collateralAmount);
        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(credit.balanceOf(address(term2)), 0);
        assertEq(term2.getLoan(loanId).borrower, address(this));
        assertEq(term2.getLoan(loanId).borrowAmount, borrowAmount);
        assertEq(
            term2.getLoanDebt(loanId),
            borrowAmount + 1_000e18 /*openingFee*/
        );
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
        assertEq(term.getLoan(loanId).borrowTime, block.timestamp);

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
        uint256 _weight = guild.getGaugeWeight(address(term));
        // debt ceiling = min(_HARDCAP, buffer) if there is only one term
        assertEq(term.debtCeiling(), _HARDCAP);
        vm.prank(governor);
        rlcm.setBufferCap(uint128(_HARDCAP / 2));
        assertEq(term.debtCeiling(), _HARDCAP / 2);
        vm.prank(governor);
        rlcm.setBufferCap(type(uint128).max);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3 days);
        assertEq(term.debtCeiling(), _HARDCAP);

        // if no weight is given to the term, debt ceiling is 0
        assertEq(term.debtCeiling(-int256(_weight)), 0);

        // add another gauge, equal voting weight for the 2nd gauge
        guild.addGauge(1, address(this));

        guild.mint(address(this), _weight);
        guild.incrementGauge(address(this), _weight);

        // debt ceiling is _HARDCAP because credit totalSupply is 0
        // and first-ever mint does not check relative debt ceilings
        assertEq(term.debtCeiling(), _HARDCAP);

        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(address(this), collateralAmount * 2);
        collateral.approve(address(term), collateralAmount * 2);

        // first borrow works
        term.borrow(borrowAmount, collateralAmount);
        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);

        // debt ceiling is 50% of totalSupply
        // + 20% of tolerance (10_000e18 + 2_000e18)
        assertEq(term.debtCeiling(), 12_000e18);

        // if the term's weight is above 100% when we include tolerance,
        // the debt ceiling is the hardCap
        guild.decrementGauge(address(this), _weight * 9 / 10);
        assertEq(term.debtCeiling(), _HARDCAP);
        guild.incrementGauge(address(this), _weight * 9 / 10);

        // second borrow fails because of relative debt ceilings
        vm.expectRevert("LendingTerm: debt ceiling reached");
        term.borrow(borrowAmount, collateralAmount);

        // mint more CREDIT, so that debt ceiling of all terms is increased
        // new totalSupply is 100_000e18, with 20_000e18 already borrowed on this term.
        credit.mint(address(this), 80_000e18);
        // if someone borrows 100_000e18, new totalSupply is 200_000e18, and debt ceiling
        // of this term is 50% of the new totalSupply, i.e. 100_000e18.
        // add 20% of tolerance (20_000e18) => 120_000e18
        assertEq(term.debtCeiling(), 120_000e18);

        vm.prank(governor);
        rlcm.setBufferCap(uint128(70_000e18));
        assertEq(term.debtCeiling(), 70_000e18);
        vm.prank(governor);
        rlcm.setBufferCap(type(uint128).max);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3 days);
        assertEq(term.debtCeiling(), 120_000e18);
        vm.prank(governor);
        term.setHardCap(60_000e18);
        assertEq(term.debtCeiling(), 60_000e18);
        vm.prank(governor);
        term.setHardCap(_HARDCAP);
        assertEq(term.debtCeiling(), 120_000e18);

        // borrow max
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        collateral.mint(address(this), 9999e18);
        collateral.approve(address(term), 9999e18);
        uint256 maxBorrow = term.debtCeiling() - term.issuance();
        term.borrow(maxBorrow, 9999e18);
        assertEq(term.issuance(), term.debtCeiling());

        // borrowing even the minimum amount will revert
        // because debt ceiling is reached
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        collateral.mint(address(this), 9999e18);
        collateral.approve(address(term), 9999e18);
        uint256 _minBorrow = profitManager.minBorrow();
        vm.expectRevert("LendingTerm: debt ceiling reached");
        term.borrow(_minBorrow, 9999e18);
    }

    // borrow fail because hardcap is reached
    function testBorrowFailHardcapReached() public {
        // prepare
        uint256 borrowAmount = _HARDCAP * 2;
        uint256 collateralAmount = (borrowAmount * 2 * 1e18) /
            _CREDIT_PER_COLLATERAL_TOKEN;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);

        // borrow
        vm.expectRevert("LendingTerm: hardcap reached");
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
    function testBorrowFuzz(
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint256 interestTime
    ) public {
        // fuzz conditions
        collateralAmount = bound(collateralAmount, 1, 1e32);
        borrowAmount = bound(borrowAmount, 1, 1e32);
        interestTime = bound(interestTime, 1, 10 * 365 * 24 * 3600);

        // do not fuzz reverting conditions (below MIN_BORROW or above maxBorrow)
        borrowAmount += profitManager.minBorrow();
        uint256 maxBorrow = collateralAmount * _CREDIT_PER_COLLATERAL_TOKEN / 1e18;
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
        uint256 interestAccrued = (borrowAmount *
            _INTEREST_RATE *
            interestTime) /
            term.YEAR() /
            1e18;
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
        uint256 startingTermCollateralBalance = collateral.balanceOf(
            address(term)
        );

        // repay
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        uint256 debt = term.getLoanDebt(loanId);
        credit.mint(address(this), debt - borrowAmount);
        credit.approve(address(term), debt);
        term.repay(loanId);

        assertEq(
            collateral.balanceOf(address(term)),
            startingTermCollateralBalance - collateralAmount,
            "incorrect term collateral amounts"
        );
        assertEq(
            collateral.balanceOf(address(this)),
            collateralAmount,
            "incorrect user collateral amount"
        );

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
        assertEq(term.issuance(), 10_000e18);
        assertEq(term.getLoan(loanId).borrowAmount, 10_000e18);
        assertEq(term.getLoanDebt(loanId), 11_000e18);
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

        uint256 MIN_BORROW = profitManager.minBorrow();
        vm.expectRevert("LendingTerm: below min borrow");
        term.partialRepay(loanId, 11_000e18 - MIN_BORROW + 1);

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

        // offboard term
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        guild.removeGauge(address(term));

        // call
        term.call(loanId);

        assertEq(term.getLoan(loanId).caller, address(this));
        assertEq(term.getLoan(loanId).callTime, block.timestamp);

        // cannot set auctionHouse because an auction is in progress
        vm.prank(governor);
        vm.expectRevert("LendingTerm: auctions in progress");
        term.setAuctionHouse(address(this));
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

        // offboard term
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        guild.removeGauge(address(term));

        // call
        term.callMany(loanIds);

        assertEq(term.getLoan(loanId).caller, address(this));
        assertEq(term.getLoan(loanId).callTime, block.timestamp);
    }

    // call success
    function testCallFailConditionsNotMet() public {
        // prepare & borrow
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // call
        vm.expectRevert("LendingTerm: cannot call");
        term.call(loanId);
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

        // offboard term
        guild.removeGauge(address(term));

        // call
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

        // offboard term
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        guild.removeGauge(address(term));

        // call
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

        // offboard term
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        guild.removeGauge(address(term));

        // call
        vm.expectRevert("LendingTerm: loan closed");
        term.call(loanId);
    }

    // if loan missed a periodic partialRepay, can call it
    function testCallAfterPartialRepayDelay() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // wait partialRepay delay
        assertEq(term.partialRepayDelayPassed(loanId), false);
        vm.warp(block.timestamp + term.YEAR() * 2 + 1);
        vm.roll(block.number + 1);
        assertEq(term.partialRepayDelayPassed(loanId), true);

        // call
        uint256 callDebt = term.getLoanDebt(loanId);
        term.call(loanId);

        // loan is called
        assertEq(term.getLoan(loanId).callTime, block.timestamp);
        assertEq(term.getLoan(loanId).callDebt, callDebt);

        // issuance not yet decremented
        assertEq(term.issuance(), borrowAmount);

        // borrower kept credit, collateral still escrowed
        assertEq(credit.balanceOf(address(this)), borrowAmount);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);
    }

    function testForgiveFailLoanNotFound() public {
        // forgive
        vm.prank(governor);
        vm.expectRevert("LendingTerm: loan not found");
        term.forgive(bytes32(0));
    }

    // test governor-only setter for auctionHouse
    function testGovernorSetAuctionHouse() public {
        assertEq(term.getReferences().auctionHouse, address(auctionHouse));

        vm.prank(governor);
        term.setAuctionHouse(address(this));

        assertEq(term.getReferences().auctionHouse, address(this));

        vm.expectRevert("UNAUTHORIZED");
        term.setAuctionHouse(address(auctionHouse));
    }

    // test setter for hardCap
    function testSetHardCap() public {
        assertEq(term.getParameters().hardCap, _HARDCAP);

        vm.prank(governor);
        term.setHardCap(type(uint256).max);

        assertEq(term.getParameters().hardCap, type(uint256).max);

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

    // full flow test (borrow, call, onBid with good debt)
    function testFlowBorrowCallOnBidGoodDebt() public {
        bytes32 loanId = keccak256(
            abi.encode(address(this), address(term), block.timestamp)
        );

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
        guild.removeGauge(address(term));
        address caller = address(1000);
        vm.prank(caller);
        term.call(loanId);

        // debt stops accruing after call
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        vm.warp(block.timestamp + 1300);
        vm.roll(block.number + 100);
        assertEq(term.getLoanDebt(loanId), 22_000e18);

        assertEq(term.getLoan(loanId).caller, caller);
        assertEq(term.getLoan(loanId).callTime, block.timestamp - 1300);
        assertEq(term.getLoan(loanId).closeTime, 0);
        assertEq(credit.balanceOf(address(this)), 22_000e18);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // represent a credit saver
        address saver = address(12090192);
        credit.mint(saver, 100);
        vm.prank(saver);
        credit.enterRebase();

        // auction bid
        address bidder = address(1269127618);
        credit.transfer(bidder, 22_000e18);
        vm.prank(bidder);
        credit.approve(address(term), 22_000e18);
        vm.prank(address(auctionHouse));
        term.onBid(
            loanId,
            bidder,
            3e18, // collateralToBorrower
            12e18, // collateralToBidder
            22_000e18 // creditFromBidder
        );

        // check token movements
        assertEq(collateral.balanceOf(address(this)), 3e18);
        assertEq(collateral.balanceOf(bidder), 12e18);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(bidder), 0);
        assertEq(credit.balanceOf(saver), 100); // profit interpolated over time
        assertEq(credit.totalSupply(), 100);
        vm.warp(block.timestamp + credit.DISTRIBUTION_PERIOD());
        assertEq(credit.balanceOf(saver), 2_000e18 + 100); // profit distributed to saver
        assertEq(credit.totalSupply(), 2_000e18 + 100);
    }

    // full flow test (borrow, call, onBid with bad debt)
    function testFlowBorrowCallOnBidBadDebt() public {
        bytes32 loanId = keccak256(
            abi.encode(address(this), address(term), block.timestamp)
        );

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
        guild.removeGauge(address(term));
        address caller = address(1000);
        vm.prank(caller);
        term.call(loanId);

        // auction bid
        address bidder = address(9182098102982);
        credit.mint(bidder, 10_000e18);
        vm.prank(bidder);
        credit.approve(address(term), 10_000e18);
        vm.prank(address(auctionHouse));
        term.onBid(
            loanId,
            bidder,
            0, // collateralToBorrower
            15e18, // collateralToBidder
            10_000e18 // creditFromBidder
        );

        // check token movements
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(bidder), 15e18);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(term)), 0);
        assertEq(credit.balanceOf(address(this)), 20_000e18);
        assertEq(credit.balanceOf(bidder), 0);
        assertEq(credit.totalSupply(), 20_000e18);

        // check loss reported
        assertEq(guild.lastGaugeLoss(address(term)), block.timestamp);
    }

    // full flow test (borrow, forgive)
    function testFlowBorrowForgive() public {
        bytes32 loanId = keccak256(
            abi.encode(address(this), address(term), block.timestamp)
        );

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
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), collateralAmount);

        // check loss reported
        assertEq(guild.lastGaugeLoss(address(term)), block.timestamp);

        // cannot forgive twice
        // forgive
        vm.prank(governor);
        vm.expectRevert("LendingTerm: loan closed");
        term.forgive(loanId);
    }

    // active loans are marked up when CREDIT lose value
    function testActiveLoansAreMarkedUpWhenCreditLoseValue() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        assertEq(profitManager.creditMultiplier(), 1e18);
        vm.prank(address(term));
        profitManager.notifyPnL(address(term), int256(-10_000e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        // active loan debt is marked up 2x
        assertEq(term.getLoanDebt(loanId), 44_000e18);

        // repay loan
        credit.mint(address(this), 24_000e18);
        credit.approve(address(term), 44_000e18);
        term.repay(loanId);

        // loan is closed
        assertEq(term.getLoanDebt(loanId), 0);
        assertEq(credit.totalSupply(), 0);
        assertEq(credit.balanceOf(address(this)), 0);
    }

    // can borrow more when CREDIT lose value
    function testCanBorrowMoreAfterCreditLoseValue() public {
        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        credit.mint(address(this), 100e18);
        assertEq(profitManager.creditMultiplier(), 1e18);
        vm.prank(address(term));
        profitManager.notifyPnL(address(term), int256(-50e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);
        credit.burn(100e18);

        // borrow
        uint256 borrowAmount = 40_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 44_000e18);
        assertEq(credit.totalSupply(), 40_000e18);

        // repay loan
        credit.mint(address(this), 4_000e18);
        credit.approve(address(term), 44_000e18);
        term.repay(loanId);

        // loan is closed
        assertEq(term.getLoanDebt(loanId), 0);
        assertEq(credit.totalSupply(), 0);
        assertEq(credit.balanceOf(address(this)), 0);
    }

    function testCannotUpdateAfterCall() public {
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

        // call
        guild.removeGauge(address(term));
        term.call(loanId);

        // cannot partialRepay
        vm.expectRevert("LendingTerm: loan called");
        term.partialRepay(loanId, 5_000e18);

        // cannot addCollateral
        vm.expectRevert("LendingTerm: loan called");
        term.addCollateral(loanId, 5_000e18);

        // cannot repay
        vm.expectRevert("LendingTerm: loan called");
        term.repay(loanId);
    }

    function testProfitAccountingRepayAfterMarkUp() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        assertEq(profitManager.creditMultiplier(), 1e18);
        vm.prank(address(term));
        profitManager.notifyPnL(address(term), int256(-10_000e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        // active loan debt is marked up 2x
        assertEq(term.getLoanDebt(loanId), 44_000e18);

        // add a saving user to keep track of distriuted profit
        credit.mint(address(this), 100);
        credit.enterRebase();

        // repay loan
        credit.mint(address(this), 24_000e18);
        credit.approve(address(term), 44_000e18);
        term.repay(loanId);

        // loan is closed, profit is distributed
        assertEq(term.getLoanDebt(loanId), 0);
        assertEq(credit.balanceOf(address(this)), 100);
        vm.warp(block.timestamp + credit.DISTRIBUTION_PERIOD());
        assertEq(credit.balanceOf(address(this)), 100 + 4_000e18);
    }

    function testProfitAccountingPartialRepayAfterMarkUp() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        assertEq(profitManager.creditMultiplier(), 1e18);
        vm.prank(address(term));
        profitManager.notifyPnL(address(term), int256(-10_000e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        // active loan debt is marked up 2x
        assertEq(term.getLoanDebt(loanId), 44_000e18);

        // add a saving user to keep track of distriuted profit
        credit.mint(address(this), 100);
        credit.enterRebase();

        // partially repay loan (50%)
        credit.mint(address(this), 2_000e18);
        credit.approve(address(term), 22_000e18);
        term.partialRepay(loanId, 22_000e18);

        // loan is 50% repaid, profit is distributed
        assertEq(term.issuance(), 10_000e18);
        assertEq(term.getLoan(loanId).borrowAmount, 10_000e18);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        assertEq(credit.balanceOf(address(this)), 100);
        vm.warp(block.timestamp + credit.DISTRIBUTION_PERIOD());
        assertEq(credit.balanceOf(address(this)), 100 + 2_000e18);
    }

    function testProfitAccountingCallBidAfterMarkUp() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        assertEq(profitManager.creditMultiplier(), 1e18);
        vm.prank(address(term));
        profitManager.notifyPnL(address(term), int256(-10_000e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        // active loan debt is marked up 2x
        assertEq(term.getLoanDebt(loanId), 44_000e18);

        // add a saving user to keep track of distriuted profit
        credit.mint(address(this), 100);
        credit.enterRebase();

        // seize
        guild.removeGauge(address(term));
        term.call(loanId);

        // bid at midpoint (pay full debt, get full collateral)
        vm.warp(block.timestamp + auctionHouse.midPoint());
        vm.roll(block.number + 1);
        credit.mint(address(this), 24_000e18);
        credit.approve(address(term), 44_000e18);
        auctionHouse.bid(loanId);

        // loan is repaid, profit is distributed
        assertEq(term.issuance(), 0);
        assertEq(term.getLoanDebt(loanId), 0);
        assertEq(credit.balanceOf(address(this)), 100);
        vm.warp(block.timestamp + credit.DISTRIBUTION_PERIOD());
        assertEq(credit.balanceOf(address(this)), 100 + 4_000e18);
    }

    function testProfitAccountingForgiveAfterMarkUp() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        assertEq(profitManager.creditMultiplier(), 1e18);
        credit.mint(address(this), 20_000e18);
        vm.prank(address(term));
        profitManager.notifyPnL(address(term), int256(-20_000e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        // active loan debt is marked up 2x
        assertEq(term.getLoanDebt(loanId), 44_000e18);

        // forgive loan
        // loan debt principal = 20k * 2 = 40k
        // totalSupply = 20k (borrowed) + 20k (bad debt in other terms) = 40k
        // should put creditMultiplier to 0 (all circulating CREDIT is bad)
        vm.prank(governor);
        term.forgive(loanId);
        assertEq(profitManager.creditMultiplier(), 0);
    }

    // MIN_BORROW increases when creditMultiplier decreases - borrow()
    function testMinBorrowAfterCreditLoseValue1() public {
        uint256 MIN_BORROW = profitManager.minBorrow();

        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        credit.mint(address(this), 100e18);
        assertEq(profitManager.creditMultiplier(), 1e18);
        vm.prank(address(term));
        profitManager.notifyPnL(address(term), int256(-50e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);
        credit.burn(100e18);

        // borrow should fail because we try to borrow 1.75x
        // the MIN_BORROW, but CREDIT value went up 2x.
        vm.expectRevert("LendingTerm: borrow amount too low");
        term.borrow((MIN_BORROW * 175) / 100, 10000000000e18);
    }

    // MIN_BORROW increases when creditMultiplier decreases - partialRepay()
    function testMinBorrowAfterCreditLoseValue() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 15e18;
        collateral.mint(address(this), collateralAmount);
        collateral.approve(address(term), collateralAmount);
        bytes32 loanId = term.borrow(borrowAmount, collateralAmount);

        // 1 year later, interest accrued
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), 22_000e18);
        assertEq(credit.totalSupply(), 20_000e18);

        // prank the term to report a loss in another loan
        // this should discount CREDIT value by 50%, marking up
        // all loans by 2x.
        assertEq(profitManager.creditMultiplier(), 1e18);
        credit.mint(address(this), 20_000e18);
        vm.prank(address(term));
        profitManager.notifyPnL(address(term), int256(-20_000e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        // active loan debt is marked up 2x
        assertEq(term.getLoanDebt(loanId), 44_000e18);

        // attempt to partialRepay with a resulting loan below MIN_BORROW
        credit.mint(address(this), 4_000e18);
        assertEq(credit.balanceOf(address(this)), 44_000e18);
        credit.approve(address(term), 41_000e18);
        term.partialRepay(loanId, 41_000e18);
    }
}
