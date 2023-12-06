// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "@forge-std/Test.sol";

import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestBorrowSDAICollateral is PostProposalCheckFixture {
    function testVoteForSDAIGauge() public {
        uint256 mintAmount = governor.quorum(0);
        /// setup
        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(address(this), mintAmount);
        guild.delegate(address(this));

        assertTrue(guild.isGauge(address(term)));
    }

    function testAllocateGaugeToSDAI() public {
        testVoteForSDAIGauge();
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

    function testSupplyCollateralUserOne(
        uint128 supplyAmount
    ) public returns (bytes32 loanId, uint128 suppliedAmount) {
        testAllocateGaugeToSDAI();

        supplyAmount = uint128(
            _bound(supplyAmount, profitManager.minBorrow(), term.debtCeiling())
        );
        suppliedAmount = supplyAmount;

        return _supplyCollateralUserOne(suppliedAmount);
    }

    function _supplyCollateralUserOne(
        uint128 supplyAmount
    ) private returns (bytes32 loanId, uint128 suppliedAmount) {
        testAllocateGaugeToSDAI();

        suppliedAmount = supplyAmount;

        deal(address(collateralToken), userOne, supplyAmount);

        uint256 startingTotalSupply = credit.totalSupply();
        uint256 startingSDaiBalance = sdai.balanceOf(address(term));
        uint256 startingBuffer = rateLimitedCreditMinter.buffer();

        vm.startPrank(userOne);
        sdai.approve(address(term), supplyAmount);
        loanId = term.borrow(supplyAmount, supplyAmount); /// borrow amount equals supply amount
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), supplyAmount, "incorrect loan debt");
        assertEq(
            sdai.balanceOf(address(term)) - startingSDaiBalance,
            supplyAmount,
            "sdai balance of term incorrect"
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

    function testRepayLoan(uint128 seed) public {
        uint256 startingCreditSupplyBeforeSupplyingCollateral = credit
            .totalSupply(); /// start off at 100
            uint256 startingBuffer = rateLimitedCreditMinter.buffer();
        (bytes32 loanId, uint128 suppliedAmount) = testSupplyCollateralUserOne(
            seed
        ); /// borrow 100
        uint256 startingCreditSupply = credit.totalSupply(); /// start off at 100

        /// total supply is 100

        vm.warp(block.timestamp + 1);

        /// account for accrued interest, adjust total supply of credit
        uint256 loanDebt = term.getLoanDebt(loanId);
        uint256 interest = loanDebt - suppliedAmount;

        deal(address(credit), userTwo, loanDebt, true); /// mint 101 CREDIT to userOne to repay debt
        /// total supply is 201

        uint256 startingIssuance = term.issuance();

        vm.startPrank(userTwo);
        credit.approve(address(term), term.getLoanDebt(loanId));
        term.repay(loanId);
        vm.stopPrank();

        /// total supply is 101

        {
            /// only creditSplit does not go into the total supply
            (
                uint256 surplusSplit,
                ,
                uint256 guildSplit,
                uint256 otherSplit,

            ) = profitManager.getProfitSharingConfig();

            uint256 expectedInterestAddedToSupply = (
                ((interest * (surplusSplit / 1e9)) /
                    1e9 +
                    ((interest * (guildSplit / 1e9)) / 1e9) +
                    (interest * (otherSplit / 1e9)) /
                    1e9)
            );

            /// minted 100 credit tokens to start, then 101 to repay, this means supplied amount is doubled
            /// in terms of total supply
            assertEq(
                credit.totalSupply() - startingCreditSupply,
                expectedInterestAddedToSupply, /// only interest for surplus, guild and other split should have been added to the supply
                "incorrect credit supply before interpolating"
            );
        }

        uint256 repayTime = block.timestamp;

        vm.warp(block.timestamp + credit.DISTRIBUTION_PERIOD());

        /// total supply is 201

        assertEq(term.getLoanDebt(loanId), 0, "incorrect loan debt");

        assertEq(
            sdai.balanceOf(address(term)),
            0,
            "sdai balance of term incorrect"
        );
        assertEq(
            credit.totalSupply(),
            interest +
                startingCreditSupplyBeforeSupplyingCollateral +
                suppliedAmount,
            "incorrect credit supply"
        );
        assertEq(
            credit.balanceOf(userOne),
            suppliedAmount,
            "incorrect credit balance"
        );

        assertEq(
            rateLimitedCreditMinter.buffer(),
            startingBuffer,
            "incorrect buffer"
        );

        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            repayTime,
            "incorrect last buffer used time"
        );
        assertEq(
            startingIssuance - term.issuance(),
            suppliedAmount,
            "incorrect issuance delta"
        );
    }

    function testTermOffboarding() public {
        if (guild.balanceOf(address(this)) == 0) {
            testVoteForSDAIGauge();
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

    function testPSMMint(uint128 amount) public {
        /// mint CREDIT between .01 USDC and buffer capacity
        amount = uint128(
            _bound(amount, 0.01e6, rateLimitedCreditMinter.buffer() / 1e12)
        );

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

    function testBid() public {
        bytes32 loanId = testCallLoan();
        uint256 creditRepayAmount = term.getLoanDebt(loanId);
        uint256 loanAmount = 10_000e18;

        uint256 profit = creditRepayAmount - loanAmount;

        uint256 usdcMintAmount = creditRepayAmount / 1e12 + 1;
        uint256 startingDeployerBalance = credit.balanceOf(userThree);

        _doMint(userTwo, uint128(usdcMintAmount)); /// round amount of credit up

        uint256 startingCreditSupply = credit.totalSupply();
        uint256 userTwoStartingCreditBalance = credit.balanceOf(userTwo);

        /// bid at start of auction, so receive 0 collateral

        vm.startPrank(userTwo);

        credit.approve(address(term), creditRepayAmount);
        auctionHouse.bid(loanId);
        uint256 loanCloseTime = block.timestamp;

        vm.stopPrank();

        vm.warp(block.timestamp + credit.DISTRIBUTION_PERIOD());

        uint256 endingDeployerBalance = credit.balanceOf(userThree);
        LendingTerm.Loan memory loan = term.getLoan(loanId);

        {
            /// credit holders receive 9/10th's of interest
            (
                uint256 surplusSplit,
                ,
                uint256 guildSplit,
                uint256 otherSplit,

            ) = profitManager.getProfitSharingConfig();

            uint256 nonCreditInterest = (
                ((profit * (surplusSplit / 1e9)) /
                    1e9 +
                    ((profit * (guildSplit / 1e9)) / 1e9) +
                    (profit * (otherSplit / 1e9)) /
                    1e9)
            );

            // uint256 userProfit = profit - nonCreditInterest; /// calculate profits exactly how the profit manager does
            /// profit is correctly distributed to deployer
            /// profit manager rounds down for all other items and rounds up in favor of credit holders when distributing profits
            assertEq(
                endingDeployerBalance,
                startingDeployerBalance + (profit - nonCreditInterest), /// user profit = profit - nonCreditInterest
                "incorrect deployer credit balance"
            );
        }

        assertEq(loan.closeTime, loanCloseTime, "incorrect close time");
        assertEq(
            auctionHouse.nAuctionsInProgress(),
            0,
            "incorrect number of auctions post bid"
        );
        assertEq(sdai.balanceOf(userTwo), 0, "incorrect sdai balance userTwo");
        assertEq(
            sdai.balanceOf(userOne),
            loanAmount,
            "incorrect sdai balance userOne"
        );
        assertEq(
            credit.balanceOf(userOne),
            loanAmount,
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
            startingCreditSupply - loanAmount, /// creditRepayAmount and burned amount got taken out of supply
            credit.totalSupply(),
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
            expectedSurplusBuffer,
            "incorrect surplus buffer"
        );
        /// credit balance in profit manager is sum of surplus, other and guild amount
        /// credit amount gets burned in the Credit Token by calling distribute
        assertEq(
            expectedSurplusBuffer + expectedOtherAmount + expectedGuildAmount,
            credit.balanceOf(address(profitManager)),
            "incorrect credit amount in profit manager"
        );
    }

    function testDistributeReducesCreditTotalSupplyOneUserRebasing(
        uint128 creditAmount
    ) public {
        /// between 10 wei and entire buffer
        creditAmount = uint128(
            _bound(creditAmount, 10, rateLimitedCreditMinter.buffer() / 1e12)
        );

        _doMint(userOne, creditAmount);

        uint256 startingCreditSupply = credit.totalSupply();

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

    function testDistributeReducesCreditTotalSupply(
        uint128 creditAmount
    ) public {
        vm.prank(userThree);
        credit.exitRebase();

        /// between 1 wei and entire buffer
        creditAmount = uint128(
            _bound(creditAmount, 1, rateLimitedCreditMinter.buffer() / 1e12)
        );

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
