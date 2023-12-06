// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@forge-std/Test.sol";

import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestBadDebtFlows is PostProposalCheckFixture {
    function testVoteForSDAIGauge() public {
        uint256 mintAmount = governor.quorum(0);
        /// setup
        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(address(this), mintAmount);
        guild.delegate(address(this));

        assertTrue(guild.isGauge(address(term)));
        assertEq(guild.balanceOf(address(this)), mintAmount);
    }

    function testAllocateGaugeToSDAI() public {
        testVoteForSDAIGauge();

        guild.incrementGauge(address(term), guild.balanceOf(address(this)));

        assertEq(guild.totalWeight(), guild.balanceOf(address(this)));
        assertTrue(guild.isUserGauge(address(this), address(term)));
    }

    function _supplyCollateralUserOne(
        uint256 borrowAmount,
        uint128 supplyAmount
    ) private returns (bytes32 loanId) {
        deal(address(collateralToken), userOne, supplyAmount);

        uint256 startingCreditSupply = credit.totalSupply();
        uint256 startingBuffer = rateLimitedCreditMinter.buffer();

        vm.startPrank(userOne);
        sdai.approve(address(term), supplyAmount);
        loanId = term.borrow(borrowAmount, supplyAmount);
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), borrowAmount, "incorrect loan debt");
        assertEq(
            sdai.balanceOf(address(term)),
            supplyAmount,
            "sdai balance of term incorrect"
        );
        assertEq(
            credit.totalSupply(),
            borrowAmount + startingCreditSupply,
            "incorrect credit supply"
        );
        assertEq(
            credit.balanceOf(userOne),
            borrowAmount,
            "incorrect credit balance"
        );
        assertEq(
            rateLimitedCreditMinter.buffer(),
            startingBuffer - borrowAmount,
            "incorrect buffer"
        );
        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            block.timestamp,
            "incorrect last buffer used time"
        );
        assertEq(term.issuance(), borrowAmount, "incorrect supply issuance");
    }

    function testTermOffboarding() public {
        if (guild.balanceOf(address(this)) == 0) {
            testVoteForSDAIGauge();
        }

        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 1);

        offboarder.proposeOffboard(address(term));
        vm.roll(block.number + 1);
        offboarder.supportOffboard(block.number - 1, address(term));
        assertFalse(
            psm.redemptionsPaused(),
            "PSM redemptions should not be paused"
        );
        offboarder.offboard(address(term));

        assertTrue(psm.redemptionsPaused(), "PSM redemptions not paused");
        assertFalse(
            guild.isGauge(address(term)),
            "term still a non-deprecated gauge"
        );
        assertTrue(
            guild.isDeprecatedGauge(address(term)),
            "term not deprecated"
        );
    }

    function _psmMint(uint128 amount) public {
        /// mint CREDIT between .01 USDC and buffer capacity
        amount = uint128(
            _bound(amount, 0.01e6, rateLimitedCreditMinter.buffer() / 1e12)
        );

        _doMint(userTwo, amount);
    }

    function _doMint(address to, uint128 amount) private returns (uint256) {
        deal(address(usdc), to, amount);

        uint256 startingUsdcBalance = usdc.balanceOf(to);
        uint256 startingCreditBalance = credit.balanceOf(to);

        vm.startPrank(to);
        usdc.approve(address(psm), amount);
        uint256 amountOut = psm.mint(to, amount);
        vm.stopPrank();

        uint256 endingUsdcBalance = usdc.balanceOf(to);
        uint256 endingCreditBalance = credit.balanceOf(to);

        assertEq(
            startingCreditBalance + amountOut,
            endingCreditBalance,
            "incorrect credit balance"
        );
        assertEq(
            startingUsdcBalance - amount,
            endingUsdcBalance,
            "incorrect usdc balance"
        );

        return amountOut;
    }

    function testBadDebtRepricesCreditBid() public {
        testAllocateGaugeToSDAI();

        uint256 borrowAmount = 100e18;
        uint128 supplyAmount = 100e18;

        /// supply collateral and borrow

        bytes32 loanId = _supplyCollateralUserOne(borrowAmount, supplyAmount);

        /// offboard term

        testTermOffboarding();

        /// test cannot redeem in PSM once that feature merges

        /// call loans

        term.call(loanId);

        /// wait for auction to allow seizing of collateral for 0 credit

        vm.warp(block.timestamp + auctionHouse.auctionDuration() + 1);

        /// seize, check collateral balance of liquidator

        (uint256 collateralReceived, uint256 creditAsked) = auctionHouse
            .getBidDetail(loanId);

        assertEq(
            collateralReceived,
            supplyAmount,
            "incorrect collateral received"
        );
        assertEq(creditAsked, 0, "incorrect credit asked");
        assertEq(auctionHouse.nAuctionsInProgress(), 1);

        rateLimitedCreditMinter.buffer();

        vm.expectRevert("AuctionHouse: cannot bid 0");
        auctionHouse.bid(loanId);

        assertEq(auctionHouse.nAuctionsInProgress(), 1);
    }

    function testBadDebtRepricesCreditForgive() public {
        testAllocateGaugeToSDAI();

        uint256 borrowAmount = 100e18;
        uint128 supplyAmount = 100e18;

        /// supply collateral and borrow

        bytes32 loanId = _supplyCollateralUserOne(borrowAmount, supplyAmount);

        /// offboard term

        testTermOffboarding();

        /// test cannot redeem in PSM once that feature merges

        /// call loans

        term.call(loanId);

        /// wait for auction to allow seizing of collateral for 0 credit

        vm.warp(block.timestamp + auctionHouse.auctionDuration() + 1);

        /// seize, check collateral balance of liquidator

        (uint256 collateralReceived, uint256 creditAsked) = auctionHouse
            .getBidDetail(loanId);

        assertEq(
            collateralReceived,
            supplyAmount,
            "incorrect collateral received"
        );
        assertEq(creditAsked, 0, "incorrect credit asked");
        assertEq(auctionHouse.nAuctionsInProgress(), 1);

        uint256 startingSdaiBalance = sdai.balanceOf(address(this));
        uint256 startingCreditSupply = credit.totalSupply();
        uint256 startingCreditMultiplier = profitManager.creditMultiplier();
        uint256 startingCreditBuffer = rateLimitedCreditMinter.buffer();
        uint256 startingIssuance = term.issuance();

        auctionHouse.forgive(loanId);

        uint256 endingSdaiBalance = sdai.balanceOf(address(this));

        assertEq(auctionHouse.nAuctionsInProgress(), 0);
        assertEq(
            endingSdaiBalance,
            startingSdaiBalance,
            "incorrect sdai balance after liquidation"
        );

        /// ensure credit reprices

        uint256 expectedCreditMultiplier = (startingCreditMultiplier *
            (startingCreditSupply - borrowAmount)) / startingCreditSupply;

        assertEq(
            startingCreditBuffer,
            rateLimitedCreditMinter.buffer(),
            "incorrect buffer, should not change on total loss as 0 principal is repaid"
        );
        assertEq(
            profitManager.termSurplusBuffer(address(term)),
            0,
            "term surplus buffer should be 0"
        );
        assertEq(
            profitManager.surplusBuffer(),
            0,
            "surplus buffer should be 0"
        );
        assertEq(
            profitManager.creditMultiplier() < 1e18,
            true,
            "credit multiplier should be less than 1"
        );
        assertEq(
            profitManager.creditMultiplier(),
            expectedCreditMultiplier,
            "credit multiplier should expected value"
        );
        assertEq(
            startingIssuance - term.issuance(),
            borrowAmount,
            "issuance delta incorrect"
        );
    }

    function testBadDebtRepricesCreditForgive(
        uint256 borrowAmount,
        uint128 supplyAmount
    ) public {
        testAllocateGaugeToSDAI();

        supplyAmount = uint128(
            _bound(supplyAmount, profitManager.minBorrow(), term.debtCeiling())
        );
        borrowAmount = _bound(
            borrowAmount,
            profitManager.minBorrow(),
            supplyAmount
        );

        /// supply collateral and borrow

        bytes32 loanId = _supplyCollateralUserOne(borrowAmount, supplyAmount);

        /// offboard term

        testTermOffboarding();

        /// test cannot redeem in PSM once that feature merges

        /// call loans

        term.call(loanId);

        /// wait for auction to allow seizing of collateral for 0 credit

        vm.warp(block.timestamp + auctionHouse.auctionDuration() + 1);

        /// seize, check collateral balance of liquidator

        (uint256 collateralReceived, uint256 creditAsked) = auctionHouse
            .getBidDetail(loanId);

        assertEq(
            collateralReceived,
            supplyAmount,
            "incorrect collateral received"
        );
        assertEq(creditAsked, 0, "incorrect credit asked");
        assertEq(auctionHouse.nAuctionsInProgress(), 1);

        uint256 startingSdaiBalance = sdai.balanceOf(address(this));
        uint256 startingCreditSupply = credit.totalSupply();
        uint256 startingCreditMultiplier = profitManager.creditMultiplier();
        uint256 startingCreditBuffer = rateLimitedCreditMinter.buffer();
        uint256 startingIssuance = term.issuance();

        auctionHouse.forgive(loanId);

        uint256 endingSdaiBalance = sdai.balanceOf(address(this));

        assertEq(auctionHouse.nAuctionsInProgress(), 0);
        assertEq(
            endingSdaiBalance,
            startingSdaiBalance,
            "incorrect sdai balance after liquidation"
        );

        /// ensure credit reprices
        /// total loss, no principal repaid
        /// - credit multiplier reprices downwards
        /// - credit supply stays the same
        /// - surplus buffer gets slashed to 0
        /// - issuance from term decreases by principal amount

        uint256 expectedCreditMultiplier = (startingCreditMultiplier *
            (startingCreditSupply - borrowAmount)) / startingCreditSupply;

        assertEq(
            startingCreditBuffer,
            rateLimitedCreditMinter.buffer(),
            "incorrect buffer, should not change on total loss as 0 principal is repaid"
        );
        assertEq(
            profitManager.termSurplusBuffer(address(term)),
            0,
            "term surplus buffer should be 0"
        );
        assertEq(
            profitManager.surplusBuffer(),
            0,
            "surplus buffer should be 0"
        );
        assertEq(
            profitManager.creditMultiplier() < 1e18,
            true,
            "credit multiplier should be less than 1"
        );
        assertEq(
            profitManager.creditMultiplier(),
            expectedCreditMultiplier,
            "credit multiplier should expected value"
        );
        assertEq(
            startingIssuance - term.issuance(),
            borrowAmount,
            "issuance delta incorrect"
        );
    }
}
