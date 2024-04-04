// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@forge-std/Test.sol";

import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestSurplusGuildMinter is PostProposalCheckFixture {
    //// ------------------------- loan helper functions -------------------------

    /// scenarios:
    ///      1. gain scenario, user gains profit as a result of a loan being repaid with interest,
    ///    they are paid in both credit and guild.
    ///      2. loss scenario, user loses staked credit as a result of a bad debt exceeding the terms surplus buffer.
    ///    their credit is lost and they receive no guild rewards.
    ///

    /// helper functions:
    ///    update mint ratio - done
    ///    update reward ratio - done
    ///    stake credit - done
    ///    unstake credit - done
    ///    supply collateral and borrow credit - done
    ///    offboard - done
    ///    repay loan - done

    function _mintQuorumGuildAmount() private {
        uint256 mintAmount = governor.quorum(0);
        /// setup
        vm.prank(address(rateLimitedGuildMinter));
        guild.mint(address(this), mintAmount);
        guild.delegate(address(this));

        assertTrue(guild.isGauge(address(term)));
    }

    function _allocateGauge() private {
        _mintQuorumGuildAmount();

        guild.incrementGauge(address(term), guild.balanceOf(address(this)));

        assertTrue(guild.totalWeight() >= guild.balanceOf(address(this)));
        assertTrue(guild.isUserGauge(address(this), address(term)));
    }

    function testStake() public {
        uint256 stakeAmount = (surplusGuildMinter.MIN_STAKE() * 314159) /
            100000;
        _testStake(stakeAmount);
    }

    function testUnstake() public {
        uint256 stakeAmount = 1000e18;
        _testStake(stakeAmount);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        /// TODO break this out into a helper function
        uint256 startingGaugeWeight = guild.getGaugeWeight(address(term));
        uint256 startingTotalSupply = guild.totalSupply();
        uint256 startingCreditBalance = credit.balanceOf(userOne);

        uint256 guildMintAmount = (stakeAmount *
            surplusGuildMinter.mintRatio()) / 1e18;

        vm.prank(userOne);
        surplusGuildMinter.unstake(address(term), stakeAmount);

        assertEq(
            guild.totalSupply(),
            startingTotalSupply - guildMintAmount,
            "incorrect guild total supply"
        );

        assertEq(
            guild.getGaugeWeight(address(term)),
            startingGaugeWeight - guildMintAmount,
            "incorrect gauge weight"
        );

        assertEq(
            credit.balanceOf(userOne) - startingCreditBalance,
            stakeAmount,
            "incorrect credit balance"
        );

        SurplusGuildMinter.UserStake memory stake = surplusGuildMinter
            .getUserStake(userOne, address(term));

        assertEq(stake.stakeTime, 0, "incorrect stake time");
        assertEq(stake.lastGaugeLoss, 0, "incorrect lastGaugeLoss");
        assertEq(stake.credit, 0, "incorrect stake amount");
        assertEq(stake.guild, 0, "incorrect guild mint amount");
        assertEq(
            stake.profitIndex, /// start at index 1e18
            0,
            "incorrect profit index"
        );
    }

    function testSetRewardRatio() public {
        uint256 rewardRatio = 123.456e18;
        _testSetRewardRatio(rewardRatio);
    }

    function testSetMintRatio() public {
        uint256 mintRatio = 12.345e18;
        _testSetMintRatio(mintRatio);
    }

    function testCreditStakerGainsOnLoanRepayWithInterest() public {
        /// setup scenario with user borrowing, then staking CREDIT in Surplus Guild Minter
        uint256 supplyAmount = 1000e18;
        {
            uint256 warpTime = 365 days;

            /// create loan
            /// supply 1000 Collateral and receive 1000 credit as user one
            bytes32 loanId = _supplyCollateralUserOne(uint128(supplyAmount));

            /// stake credit in surplus guild minter on that term before interest accrues
            _testStake(supplyAmount);

            /// warp forward
            vm.warp(block.timestamp + warpTime);

            /// repay loan with interest
            uint256 interest = _repayLoan(loanId, supplyAmount);
            interest; /// shhhhhhh
        }

        /// Run scenario, calculate profits, Credit and Guild amounts
        /// claim rewards from surplus guild minter and ensure that user receives correct amount of credit and guild rewards
        /// userOne should get CREDIT as a reward for staking because the GUILD split is 1%, meaning 1% of all earnings of
        /// CREDIT is sent to the GUILD stakers
        uint256 startingCreditBalance = credit.balanceOf(userOne);
        uint256 startingGuildBalanceSurplusGuildMinter = guild.balanceOf(
            address(surplusGuildMinter)
        );
        uint256 startingGuildBalance = guild.balanceOf(userOne);
        uint256 startingGuildTotalSupply = guild.totalSupply();

        /// update rewards for user one, this will update the profit index for the user and mint GUILD rewards
        (, SurplusGuildMinter.UserStake memory stake, ) = surplusGuildMinter
            .getRewards(address(userOne), address(term));

        /// calculate unclaimed rewards in surplus guild minter
        /// equation:
        ///      creditRewards = (interest * guildSplit) / 1e18
        ///      guildRewards = (creditRewards * userOneGuildStakedAmount) / totalGaugeAllocation / 1e18
        ///
        /// Because the GUILD_SPLIT is set to 0 in the system creation, no CREDIT Rewards go to GUILD stakers
        /// this means that Guild stakers receive no rewards in either CREDIT or GUILD
        ///
        uint256 guildStaked = (supplyAmount * surplusGuildMinter.mintRatio()) /
            1e18;
        assertEq(guildStaked, stake.guild, "incorrect guild staked");

        /// had to throw out my old way of calculating things because it was too accurate,
        /// the indexes automatically round down and lose the last few bits of precision,
        /// due to the index math which loses precision (this is by design and completely fine)

        /// unclaimed rewards should be added to guild total supply after unstaking

        vm.prank(userOne);
        surplusGuildMinter.unstake(address(term), supplyAmount);

        uint256 guildRewards;
        {
            uint256 _profitIndex = profitManager.userGaugeProfitIndex(
                address(surplusGuildMinter),
                address(term)
            );

            /// user profit index starts at 1e18, but it gets set to the current index when getRewards is called
            /// set it to 1e18 to simulate the user not having called getRewards yet to figure out what the values should be
            uint256 _userProfitIndex = 1e18;

            uint256 deltaIndex = _profitIndex - _userProfitIndex;
            assertEq(
                credit.balanceOf(userOne) - startingCreditBalance,
                supplyAmount + ((guildStaked * deltaIndex) / 1e18),
                "incorrect credit balance user one after unstaking credit from surplus guild minter"
            );
            guildRewards =
                (((guildStaked * deltaIndex) / 1e18) *
                    surplusGuildMinter.rewardRatio()) /
                1e18;
        }

        stake = surplusGuildMinter.getUserStake(userOne, address(term));
        assertEq(0, stake.stakeTime, "incorrect last stake time");
        assertEq(0, stake.profitIndex, "incorrect profit index");
        assertEq(
            stake.credit,
            0,
            "incorrect credit amount after unstaking credit from surplus guild minter"
        );
        assertEq(
            stake.guild,
            0,
            "incorrect guild amount after unstaking credit from surplus guild minter"
        );

        assertEq(
            guild.totalSupply(),
            startingGuildTotalSupply - guildStaked + guildRewards,
            "incorrect guild total supply"
        );
        assertEq(
            guild.balanceOf(userOne) - startingGuildBalance,
            guildRewards,
            "incorrect guild balance user one"
        );
        assertEq(
            startingGuildBalanceSurplusGuildMinter -
                guild.balanceOf(address(surplusGuildMinter)),
            guildStaked,
            "incorrect guild balance in surplus guild minter"
        );
    }

    function testCreditStakerSlashOnBadDebtLossEvent() public {
        /// setup scenario with user borrowing, then staking CREDIT in Surplus Guild Minter
        uint256 supplyAmount = 1000e18;
        uint256 computedCreditAsked;
        bytes32 loanId;
        {
            uint256 warpTime = 365 days;

            /// create loan
            /// supply 1000 Collateral and receive 1000 credit as user one
            loanId = _supplyCollateralUserOne(uint128(supplyAmount));

            /// stake credit in surplus guild minter on that term before interest accrues
            _testStake(supplyAmount);

            /// warp forward
            vm.warp(block.timestamp + warpTime);

            /// enable collateral to be called
            _termOffboarding(); /// this warps time and block number

            uint256 currentDebtAmount = term.getLoanDebt(loanId);

            uint256 callTime = block.timestamp;
            uint256 midPoint = auctionHouse.midPoint();
            uint256 duration = auctionHouse.auctionDuration();
            term.call(loanId);

            assertEq(
                (auctionHouse.getAuction(loanId)).callDebt,
                currentDebtAmount,
                "incorrect call debt"
            );

            vm.warp(callTime + midPoint);

            (uint256 collateralReceived, uint256 creditAsked) = auctionHouse
                .getBidDetail(loanId);

            uint256 elapsed = block.timestamp -
                (auctionHouse.getAuction(loanId)).startTime -
                midPoint;

            computedCreditAsked =
                currentDebtAmount -
                (currentDebtAmount * elapsed) /
                (duration - midPoint);

            assertEq(elapsed, 0, "incorrect elapsed time");
            assertEq(
                creditAsked,
                computedCreditAsked,
                "incorrect credit asked"
            );
            assertEq(
                collateralReceived,
                supplyAmount,
                "incorrect collateral received"
            );

            {
                uint256 PHASE_2_DURATION = auctionHouse.auctionDuration() -
                    auctionHouse.midPoint();

                vm.warp(callTime + midPoint + PHASE_2_DURATION / 2); /// warp exactly to phase 2 midPoint
            }
            elapsed =
                block.timestamp -
                (auctionHouse.getAuction(loanId)).startTime -
                midPoint; /// should be 0

            computedCreditAsked =
                currentDebtAmount -
                (currentDebtAmount * elapsed) /
                (duration - midPoint);

            {
                uint256 PHASE_2_DURATION = auctionHouse.auctionDuration() -
                    auctionHouse.midPoint();
                assertEq(
                    elapsed,
                    PHASE_2_DURATION / 2,
                    "incorrect elapsed time 2"
                );
            }
        }

        /// now we have a bad debt loss event, repay assert the following:
        /// - user one is slashed and cannot pull credit out of the Surplus Guild Minter
        /// - surplus guild minter balance decreased by the amount of guild slashed
        /// - credit total supply is decreased by the amount of credit repaid
        /// - figure out how much we should adjust the credit multiplier by
        /// - slashed user receives still their credit reward

        dealCredit(address(this), computedCreditAsked, true);
        credit.approve(address(term), computedCreditAsked);

        SurplusGuildMinter.UserStake memory stake = surplusGuildMinter
            .getUserStake(userOne, address(term));

        uint256 startingCreditTotalSupply = credit.totalSupply();
        uint256 startingGuildTotalSupply = guild.totalSupply();
        uint256 startingCreditBalance = credit.balanceOf(address(this));
        uint256 lossAmount = supplyAmount - computedCreditAsked;

        /// repay the loan
        /// this is when the loss is applied, and repay amount + surplus buffer loss is burned
        {
            uint256 startingCreditMultiplier = profitManager.creditMultiplier();
            uint256 startingIssuance = term.issuance();
            auctionHouse.bid(loanId);
            guild.applyGaugeLoss(address(term), address(surplusGuildMinter));
            assertEq(
                startingCreditMultiplier,
                profitManager.creditMultiplier(),
                "profit multiplier incorrectly changed"
            );
            assertEq(
                startingIssuance - term.issuance(),
                supplyAmount,
                "issuance not properly decremented"
            );
        }

        assertEq(
            profitManager.termSurplusBuffer(address(term)),
            0,
            "term surplus buffer not zero after loss event"
        );
        assertEq(
            credit.totalSupply(),
            startingCreditTotalSupply - computedCreditAsked - lossAmount,
            "incorrect credit total supply"
        );
        assertEq(
            credit.balanceOf(address(this)),
            startingCreditBalance - computedCreditAsked,
            "incorrect credit balance"
        );

        assertEq(
            startingGuildTotalSupply - stake.guild,
            guild.totalSupply(),
            "incorrect guild total supply"
        );

        /// slash the user
        (
            uint256 lastGaugeLoss,
            SurplusGuildMinter.UserStake memory newStake,
            bool slashed
        ) = surplusGuildMinter.getRewards(userOne, address(term));

        assertTrue(slashed, "user not slashed");
        assertTrue(lastGaugeLoss != 0, "last gauge loss is 0");
        assertEq(newStake.guild, 0, "incorrect guild stake after slashing");
        assertEq(newStake.credit, 0, "incorrect credit stake after slashing");
    }

    //// Helper functions

    function _termOffboarding() public {
        if (guild.balanceOf(address(this)) == 0) {
            _mintQuorumGuildAmount();
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

    function _testSetMintRatio(uint256 mintRatio) private {
        vm.prank(getAddr("DAO_TIMELOCK"));

        surplusGuildMinter.setMintRatio(mintRatio);
        assertEq(
            surplusGuildMinter.mintRatio(),
            mintRatio,
            "incorrect mint ratio"
        );
    }

    function _testSetRewardRatio(uint256 rewardRatio) private {
        vm.prank(getAddr("DAO_TIMELOCK"));

        surplusGuildMinter.setRewardRatio(rewardRatio);

        assertEq(
            surplusGuildMinter.rewardRatio(),
            rewardRatio,
            "incorrect reward ratio"
        );
    }

    /// stake credit and assert that the correct amount of guild is minted
    /// @param stakeAmount the amount of credit to stake
    function _testStake(uint256 stakeAmount) private {
        // mint credit
        dealCredit(userOne, stakeAmount, true);

        uint256 startingGaugeStakeAmount = guild.getGaugeWeight(address(term));
        uint256 startingTermSurplusBuffer = profitManager.termSurplusBuffer(
            address(term)
        );
        uint256 startingTotalSupply = guild.totalSupply();

        // stake credit
        vm.startPrank(userOne);
        credit.approve(address(surplusGuildMinter), stakeAmount);
        surplusGuildMinter.stake(address(term), stakeAmount);
        vm.stopPrank();

        uint256 guildMintAmount = (stakeAmount *
            surplusGuildMinter.mintRatio()) / 1e18;
        assertEq(
            guild.totalSupply(),
            startingTotalSupply + guildMintAmount,
            "incorrect guild total supply"
        );
        assertEq(
            guild.getGaugeWeight(address(term)),
            startingGaugeStakeAmount + guildMintAmount,
            "incorrect new gauge weight"
        );

        assertEq(
            profitManager.termSurplusBuffer(address(term)),
            startingTermSurplusBuffer + stakeAmount,
            "incorrect new term surplus buffer"
        );

        SurplusGuildMinter.UserStake memory stake = surplusGuildMinter
            .getUserStake(userOne, address(term));

        assertEq(stake.stakeTime, block.timestamp, "incorrect stake time");
        assertEq(stake.lastGaugeLoss, 0, "incorrect lastGaugeLoss");
        assertEq(stake.credit, stakeAmount, "incorrect stake amount");
        assertEq(stake.guild, guildMintAmount, "incorrect guild mint amount");
        assertEq(
            stake.profitIndex, /// start at index 1e18
            1e18,
            "incorrect profit index"
        );
    }

    function _supplyCollateralUserOne(
        uint128 supplyAmount
    ) private returns (bytes32 loanId) {
        _allocateGauge();

        deal(address(collateralToken), userOne, supplyAmount);

        uint256 startingTotalSupply = credit.totalSupply();
        uint256 issuanceBefore = term.issuance();

        vm.startPrank(userOne);
        collateralToken.approve(address(term), supplyAmount);
        loanId = term.borrow(supplyAmount, supplyAmount);
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), supplyAmount, "incorrect loan debt");
        assertEq(
            collateralToken.balanceOf(address(term)),
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
            term.issuance(),
            issuanceBefore + supplyAmount,
            "incorrect supply issuance"
        );
    }

    function _repayLoan(
        bytes32 loanId,
        uint256 borrowAmount
    ) private returns (uint256 interest) {
        vm.warp(block.timestamp + 1);

        /// account for accrued interest, adjust total supply of credit
        uint256 loanDebt = term.getLoanDebt(loanId);
        interest = loanDebt - borrowAmount;

        dealCredit(userTwo, loanDebt, true); /// mint CREDIT to userOne to repay debt

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
            startingIssuance - term.issuance(),
            borrowAmount,
            "incorrect issuance delta"
        );
    }
}
