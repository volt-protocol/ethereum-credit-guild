// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@forge-std/Test.sol";

import {PostProposalCheckFixture} from "@test/integration/proposal-checks/PostProposalCheckFixture.sol";

contract IntegrationTestBadDebtFlows is PostProposalCheckFixture {
    function testVoteForSDAIGauge() public {
        uint256 mintAmount = governor.quorum(0);
        /// setup
        vm.prank(addresses.mainnet("TEAM_MULTISIG"));
        rateLimitedGuildMinter.mint(address(this), mintAmount);
        guild.delegate(address(this));

        assertTrue(guild.isGauge(address(term)));
        assertEq(guild.numGauges(), 1);
        assertEq(guild.numLiveGauges(), 1);
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
    ) public returns (bytes32 loanId) {
        deal(address(sdai), userOne, supplyAmount);

        uint256 startingCreditSupply = credit.totalSupply();

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
            rateLimitedCreditMinter.bufferCap() -
                startingCreditSupply -
                borrowAmount,
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
        offboarder.offboard(address(term));

        assertFalse(guild.isGauge(address(term)));
        assertTrue(guild.isDeprecatedGauge(address(term)));
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
        /// TODO uncomment once changes around pausing PSM when term is offboarded come online
        /// user two purchases credit in PSM
        // deal(address(usdc), userTwo, 100e6);
        // vm.startPrank(userTwo);
        // usdc.approve(address(psm), 100e6);
        // psm.mint(userTwo, 100e6);
        // vm.stopPrank();

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
        /// TODO uncomment once changes around pausing PSM when term is offboarded come online
        /// user two purchases credit in PSM
        // deal(address(usdc), userTwo, 100e6);
        // vm.startPrank(userTwo);
        // usdc.approve(address(psm), 100e6);
        // psm.mint(userTwo, 100e6);
        // vm.stopPrank();

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

        auctionHouse.forgive(loanId);

        uint256 endingSdaiBalance = sdai.balanceOf(address(this));

        assertEq(auctionHouse.nAuctionsInProgress(), 0);
        assertEq(
            endingSdaiBalance,
            startingSdaiBalance,
            "incorrect sdai balance after liquidation"
        );

        /// ensure credit reprices
        assertEq(
            profitManager.creditMultiplier() < 1e18,
            true,
            "credit multiplier should be less than 1"
        );

        /// TODO add more assertions around this to ensure that credit reprices to the right price
    }
}
