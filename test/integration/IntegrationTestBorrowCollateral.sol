// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "@forge-std/Test.sol";

import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestBorrowCollateral is PostProposalCheckFixture {
    function testVoteForGauge() public {
        uint256 mintAmount = governor.quorum(0);
        /// setup
        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(address(this), mintAmount);
        guild.delegate(address(this));

        assertTrue(guild.isGauge(address(term)));
    }

    function testAllocateGauge() public {
        testVoteForGauge();
        uint256 mintAmount = governor.quorum(0);
        uint256 startingTotalWeight = guild.totalWeight();

        guild.incrementGauge(address(term), mintAmount);

        assertEq(
            guild.totalWeight() - startingTotalWeight,
            mintAmount,
            "incorrect gauge weight post increment"
        );
        assertTrue(
            guild.isUserGauge(address(this), address(term)),
            "is user gauge false"
        );
    }

    function testSupplyCollateralUserOne() public returns (bytes32, uint128) {
        testAllocateGauge();
        uint128 amount = (uint128(profitManager.minBorrow()) * 314159) / 100000;
        return _supplyCollateralUserOne(amount);
    }

    function _supplyCollateralUserOne(
        uint128 supplyAmount
    ) private returns (bytes32 loanId, uint128 suppliedAmount) {
        testAllocateGauge();

        suppliedAmount = supplyAmount;

        deal(address(collateralToken), userOne, supplyAmount);

        uint256 startingTotalSupply = credit.totalSupply();
        uint256 startingCollateralBalance = collateralToken.balanceOf(
            address(term)
        );
        uint256 startingBuffer = rateLimitedCreditMinter.buffer();

        vm.startPrank(userOne);
        collateralToken.approve(address(term), supplyAmount);
        loanId = term.borrow(supplyAmount, supplyAmount); /// borrow amount equals supply amount
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), supplyAmount, "incorrect loan debt");
        assertEq(
            collateralToken.balanceOf(address(term)) -
                startingCollateralBalance,
            supplyAmount,
            "collateralToken balance of term incorrect"
        );
        assertEq(
            credit.totalSupply(),
            supplyAmount + startingTotalSupply,
            "incorrect credit supply"
        );
        assertEq(
            credit.balanceOf(userOne),
            supplyAmount,
            "incorrect credit balance"
        );
        assertEq(
            rateLimitedCreditMinter.buffer(),
            startingBuffer - supplyAmount,
            "incorrect buffer"
        );

        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            block.timestamp,
            "incorrect last buffer used time"
        );
        assertEq(term.issuance(), supplyAmount, "incorrect supply issuance");
    }

    function testRepayLoan() public {
        uint256 startingBuffer = rateLimitedCreditMinter.buffer();
        (bytes32 loanId, uint128 borrowAmount) = testSupplyCollateralUserOne();

        vm.warp(block.timestamp + 1);

        uint256 loanDebt = term.getLoanDebt(loanId);

        // get enough credit to repay interests
        dealCredit(userTwo, loanDebt, true);

        uint256 startingIssuance = term.issuance();

        vm.startPrank(userTwo);
        credit.approve(address(term), term.getLoanDebt(loanId));
        term.repay(loanId);
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), 0, "incorrect loan debt");

        assertEq(
            collateralToken.balanceOf(address(term)),
            0,
            "collateralToken balance of term incorrect"
        );

        assertEq(
            credit.balanceOf(userOne),
            borrowAmount,
            "incorrect credit balance"
        );

        assertEq(
            rateLimitedCreditMinter.buffer(),
            startingBuffer,
            "incorrect buffer"
        );

        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            block.timestamp,
            "incorrect last buffer used time"
        );
        assertEq(
            startingIssuance - term.issuance(),
            borrowAmount,
            "incorrect issuance delta"
        );
    }

    function testTermOffboarding() public {
        if (guild.balanceOf(address(this)) == 0) {
            testVoteForGauge();
        }

        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 1);

        assertFalse(psm.redemptionsPaused(), "psm redeem should be online"); /// psm starts online
        offboarder.proposeOffboard(address(term));

        vm.roll(block.number + 1);

        offboarder.supportOffboard(block.number - 1, address(term));
        offboarder.offboard(address(term));

        assertTrue(psm.redemptionsPaused(), "psm redeem should be offline"); /// psm paused during loan offboarding
        assertFalse(
            guild.isGauge(address(term)),
            "guild gauge should be offboarded"
        );
    }

    function testPSMMint() public {
        uint128 amount = 456.789e18;

        _doMint(userTwo, amount);
    }

    function _doMint(address to, uint128 amount) private {
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
    }

    function testCallLoan() public returns (bytes32) {
        uint256 supplyAmount = 10_000e18;
        (bytes32 loanId, ) = _supplyCollateralUserOne(uint128(supplyAmount));

        testTermOffboarding();

        uint256 loanDebt = term.getLoanDebt(loanId);

        term.call(loanId);

        assertEq(
            auctionHouse.nAuctionsInProgress(),
            1,
            "incorrect number of auctions post call"
        );

        LendingTerm.Loan memory loan = term.getLoan(loanId);

        assertEq(loan.closeTime, 0, "incorrect close time");
        assertEq(loan.callTime, block.timestamp, "incorrect call time");
        assertEq(loan.callDebt, loanDebt, "incorrect call debt");
        assertEq(loan.caller, address(this), "incorrect caller");
        assertTrue(psm.redemptionsPaused(), "incorrect psm redemptions paused");

        return loanId;
    }

    function testIntegrationBid() public {
        bytes32 loanId = testCallLoan();
        uint256 creditRepayAmount = term.getLoanDebt(loanId);

        uint256 profit = creditRepayAmount - 10_000e18;

        uint256 usdcMintAmount = creditRepayAmount / 1e12 + 1;
        uint256 startingDeployerBalance = credit.balanceOf(userThree);

        _doMint(userTwo, uint128(usdcMintAmount)); /// round amount of credit up

        uint256 startingCreditSupply = credit.targetTotalSupply();
        uint256 userTwoStartingCreditBalance = credit.balanceOf(userTwo);
        uint256 startingSurplusBuffer = profitManager.surplusBuffer();
        uint256 creditProfitManagerBalanceBefore = credit.balanceOf(address(profitManager));

        /// bid at start of auction, so receive 0 collateral

        vm.startPrank(userTwo);

        credit.approve(address(term), creditRepayAmount);
        auctionHouse.bid(loanId);
        uint256 loanCloseTime = block.timestamp;

        vm.stopPrank();

        vm.warp(block.timestamp + credit.DISTRIBUTION_PERIOD());

        {
            uint256 endingDeployerBalance = credit.balanceOf(userThree);
            LendingTerm.Loan memory loan = term.getLoan(loanId);

            // lender received non zero interests
            assertGt(endingDeployerBalance, startingDeployerBalance);

            assertEq(loan.closeTime, loanCloseTime, "incorrect close time");
        }
        assertEq(
            auctionHouse.nAuctionsInProgress(),
            0,
            "incorrect number of auctions post bid"
        );
        assertEq(
            collateralToken.balanceOf(userTwo),
            0,
            "incorrect collateralToken balance userTwo"
        );
        assertEq(
            collateralToken.balanceOf(userOne),
            10_000e18,
            "incorrect collateralToken balance userOne"
        );
        assertEq(
            credit.balanceOf(userOne),
            10_000e18,
            "incorrect credit balance userOne"
        );
        assertEq(
            credit.balanceOf(userTwo),
            userTwoStartingCreditBalance - creditRepayAmount,
            "incorrect credit balance userTwo"
        ); /// user two spent creditRepayAmount to repay the debt
        assertEq(
            auctionHouse.nAuctionsInProgress(),
            0,
            "incorrect number of auctions completed"
        );
        assertEq(term.issuance(), 0, "incorrect issuance");
        assertEq(
            startingCreditSupply - 10_000e18, /// creditRepayAmount and burned amount got taken out of supply
            credit.targetTotalSupply(),
            "incorrect credit token amount burned"
        ); /// burned 9/10ths of profit

        uint256 expectedSurplusBuffer;
        uint256 expectedOtherAmount;
        uint256 expectedGuildAmount;
        {
            (
                uint256 surplusSplit,
                ,
                uint256 guildSplit,
                uint256 otherSplit,

            ) = profitManager.getProfitSharingConfig();

            expectedSurplusBuffer = (profit * (surplusSplit / 1e9)) / 1e9;
            expectedOtherAmount = (profit * (otherSplit / 1e9)) / 1e9;
            expectedGuildAmount = (profit * (guildSplit / 1e9)) / 1e9;
        }

        assertEq(
            profitManager.surplusBuffer(),
            startingSurplusBuffer + expectedSurplusBuffer,
            "incorrect surplus buffer"
        );
        /// credit balance in profit manager is sum of surplus, other and guild amount
        /// credit amount gets burned in the Credit Token by calling distribute
        assertEq(
            creditProfitManagerBalanceBefore + expectedSurplusBuffer + expectedOtherAmount + expectedGuildAmount,
            credit.balanceOf(address(profitManager)),
            "incorrect credit amount in profit manager"
        );
    }

    function testDistributeReducesCreditTotalSupplyOneUserRebasing() public {
        uint128 creditAmount = 3654e18;

        _doMint(userOne, creditAmount);

        uint256 startingCreditSupply = credit.targetTotalSupply();

        assertFalse(credit.isRebasing(userOne));

        vm.prank(userOne);
        credit.distribute(creditAmount);

        vm.warp(block.timestamp + credit.DISTRIBUTION_PERIOD());

        assertEq(
            credit.totalSupply(),
            startingCreditSupply,
            "incorrect credit total supply"
        );
    }

    function testDistributeReducesCreditTotalSupply() public {
        vm.prank(userThree);
        credit.exitRebase();

        uint128 creditAmount = 4522.123456789e18;

        _doMint(userOne, creditAmount);

        uint256 startingCreditSupply = credit.totalSupply();

        assertFalse(credit.isRebasing(userOne));

        vm.prank(userOne);
        credit.distribute(creditAmount);

        assertEq(
            credit.totalSupply(),
            startingCreditSupply - creditAmount,
            "incorrect credit total supply"
        );
    }
}
