// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@forge-std/Test.sol";

import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {PostProposalCheckFixture} from "@test/integration/proposal-checks/PostProposalCheckFixture.sol";

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
    ///    supply collateral and borrow credit
    ///    offboard
    ///    repay loan
    ///    bid on a loan and cause bad debt

    function _voteForSDAIGauge() private {
        uint256 mintAmount = governor.quorum(0);
        /// setup
        vm.prank(addresses.mainnet("TEAM_MULTISIG"));
        rateLimitedGuildMinter.mint(address(this), mintAmount);
        guild.delegate(address(this));

        assertTrue(guild.isGauge(address(term)));
        assertEq(guild.numGauges(), 1);
        assertEq(guild.numLiveGauges(), 1);
    }

    function _allocateGaugeToSDAI() private {
        _voteForSDAIGauge();

        guild.incrementGauge(address(term), guild.balanceOf(address(this)));

        assertEq(guild.totalWeight(), guild.balanceOf(address(this)));
        assertTrue(guild.isUserGauge(address(this), address(term)));
    }

    function testStake(uint256 stakeAmount) public {
        stakeAmount = _bound(
            stakeAmount,
            surplusGuildMinter.MIN_STAKE(),
            rateLimitedCreditMinter.buffer()
        );

        _testStake(stakeAmount);
    }

    function testUnstake() public {
        uint256 stakeAmount = 1000e18;
        _testStake(stakeAmount);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        /// TODO break this out into a helper function
        uint256 startingGaugeWeight = guild.getGaugeWeight(address(term));
        uint256 startingGuildMinterBuffer = rateLimitedGuildMinter.buffer();
        uint256 startingTotalSupply = guild.totalSupply();
        uint256 startingCreditBalance = credit.balanceOf(userOne);

        uint256 guildMintAmount = (stakeAmount *
            surplusGuildMinter.mintRatio()) / 1e18;

        vm.prank(userOne);
        surplusGuildMinter.unstake(address(term), stakeAmount);

        assertEq(
            startingGuildMinterBuffer + guildMintAmount,
            rateLimitedGuildMinter.buffer(),
            "incorrect guild minter buffer"
        );

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
            stake.profitIndex, /// start at index 0
            0,
            "incorrect profit index"
        );
    }

    function testSetRewardRatio(uint256 rewardRatio) public {
        rewardRatio = _bound(rewardRatio, 1e18, 100e18);

        _testSetRewardRatio(rewardRatio);
    }

    function testSetMintRatio(uint256 mintRatio) public {
        mintRatio = _bound(mintRatio, 0.1e18, 100e18);

        _testSetMintRatio(mintRatio);
    }

    function testCreditStakerGainsOnLoanRepayWithInterest() public {
        /// add gauge weight to SDAI gauge
        _voteForSDAIGauge();

        uint256 warpTime = 365 days;
        /// create loan
        /// supply 1000 SDAI Collateral and receive 1000 credit as user one
        (bytes32 loanId, uint256 supplyAmount) = _supplyCollateralUserOne(
            1000e18
        );

        /// warp forward
        vm.warp(block.timestamp + warpTime);

        /// rewards are paid when interest accrues,
        /// interest only accrues when a user repays,
        /// so do not stake before then

        /// stake credit in surplus guild minter on that term before interest accrues
        _testStake(supplyAmount);

        /// repay loan with interest
        uint256 interest = _repayLoan(loanId, supplyAmount);

        (, , uint256 guildSplit, , ) = profitManager.getProfitSharingConfig();

        assertEq(guildSplit, 0, "Guild split not 0");

        /// calculate unclaimed rewards in surplus guild minter
        /// equation:
        ///      creditRewards = (interest * guildSplit) / 1e18
        ///      guildRewards = (creditRewards * userOneGuildStakedAmount) / totalGaugeAllocation / 1e18
        ///
        /// Because the GUILD_SPLIT is set to 0 in the system creation, no CREDIT Rewards go to GUILD stakers
        /// this means that Guild stakers receive no rewards in either CREDIT or GUILD
        ///
        uint256 creditRewards = (interest * guildSplit) / 1e18; /// should be 0
        uint256 unclaimedRewards = (creditRewards *
            surplusGuildMinter.rewardRatio()) / 1e18;

        uint256 guildStaked = (supplyAmount * surplusGuildMinter.mintRatio()) /
            1e18;

        /// unstake from surplus guild minter and ensure that user receives correct amount of credit back + guild rewards
        /// userOne should get 0 CREDIT as a reward for staking because the GUILD split is 0, meaning no CREDIT is sent to the GUILD stakers
        uint256 startingCreditBalance = credit.balanceOf(userOne);
        uint256 startingGuildBalance = guild.balanceOf(userOne);
        uint256 startingGuildBalanceSurplusGuildMinter = guild.balanceOf(
            address(surplusGuildMinter)
        );
        uint256 startingGuildTotalSupply = guild.totalSupply();
        uint256 startingGuildMinterBuffer = rateLimitedGuildMinter.buffer();

        /// supply amount * mint ratio should be added to the guild minter buffer after unstaking
        /// unclaimed rewards should be added to guild total supply after unstaking

        vm.prank(userOne);
        surplusGuildMinter.unstake(address(term), supplyAmount);

        assertEq(guild.totalSupply(), startingGuildTotalSupply - guildStaked);
        assertEq(creditRewards, 0, "incorrect credit rewards");
        assertEq(unclaimedRewards, 0, "incorrect unclaimed rewards");
        assertEq(
            credit.balanceOf(userOne) - startingCreditBalance,
            supplyAmount + unclaimedRewards,
            "incorrect credit balance"
        );
        assertEq(
            startingGuildBalance,
            guild.balanceOf(userOne),
            "incorrect guild balance user one"
        );
        assertEq(
            startingGuildBalanceSurplusGuildMinter -
                guild.balanceOf(address(surplusGuildMinter)),
            guildStaked,
            "incorrect guild balance in surplus guild minter"
        );

        /// buffer increased by guild staked amount as guild staked was burned
        assertEq(
            rateLimitedGuildMinter.buffer() - startingGuildMinterBuffer,
            guildStaked,
            "incorrect rate limited guild minter buffer"
        );
    }

    /// TODO
    function testCreditStakerSlashOnBadDebtLossEvent() public {}

    //// Helper functions

    function _testSetMintRatio(uint256 mintRatio) private {
        vm.prank(addresses.mainnet("TIMELOCK"));

        surplusGuildMinter.setMintRatio(mintRatio);
        assertEq(
            surplusGuildMinter.mintRatio(),
            mintRatio,
            "incorrect mint ratio"
        );
    }

    function _testSetRewardRatio(uint256 rewardRatio) private {
        vm.prank(addresses.mainnet("TIMELOCK"));

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
        deal(address(credit), userOne, stakeAmount, true);

        uint256 startingGaugeStakeAmount = guild.getGaugeWeight(address(term));
        uint256 startingTermSurplusBuffer = profitManager.termSurplusBuffer(
            address(term)
        );
        uint256 startingGuildMinterBuffer = rateLimitedGuildMinter.buffer();
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
            /// current buffer + (stakeAmount * mintRatio) equals starting buffer
            rateLimitedGuildMinter.buffer() + guildMintAmount,
            startingGuildMinterBuffer,
            "incorrect guild minter buffer"
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
            stake.profitIndex, /// start at index 0
            0,
            "incorrect profit index"
        );
    }

    function _supplyCollateralUserOne(
        uint128 supplyAmount
    ) private returns (bytes32 loanId, uint128 suppliedAmount) {
        supplyAmount = uint128(
            _bound(
                uint256(supplyAmount),
                term.MIN_BORROW(),
                rateLimitedCreditMinter.buffer()
            )
        );
        suppliedAmount = supplyAmount;

        _allocateGaugeToSDAI();

        deal(address(sdai), userOne, supplyAmount);

        uint256 startingTotalSupply = credit.totalSupply();

        vm.startPrank(userOne);
        sdai.approve(address(term), supplyAmount);
        loanId = term.borrow(supplyAmount, supplyAmount);
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), supplyAmount, "incorrect loan debt");
        assertEq(
            sdai.balanceOf(address(term)),
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
            rateLimitedCreditMinter.bufferCap() -
                startingTotalSupply -
                supplyAmount,
            "incorrect buffer after supply"
        );
        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            block.timestamp,
            "incorrect last buffer used time"
        );
        assertEq(term.issuance(), supplyAmount, "incorrect supply issuance");
    }

    function _repayLoan(
        bytes32 loanId,
        uint256 suppliedAmount
    ) private returns (uint256 interest) {
        uint256 startingCreditSupply = credit.totalSupply(); /// start off at 100
        // (bytes32 loanId, uint128 suppliedAmount) = _supplyCollateralUserOne(
        //     supplyAmount
        // ); /// borrow 100

        /// total supply is 200

        vm.warp(block.timestamp + 1);

        /// account for accrued interest, adjust total supply of credit
        uint256 loanDebt = term.getLoanDebt(loanId);
        interest = loanDebt - suppliedAmount;

        deal(address(credit), userTwo, loanDebt, true); /// mint 101 CREDIT to userOne to repay debt
        /// total supply is 301

        credit.totalSupply();

        vm.startPrank(userTwo);
        credit.approve(address(term), term.getLoanDebt(loanId));
        term.repay(loanId);
        vm.stopPrank();

        {
            (uint256 surplusSplit, , , , ) = profitManager
                .getProfitSharingConfig();
            assertEq(
                credit.totalSupply(),
                ((interest * surplusSplit) / 1e18) + /// 10% of interest goes into total supply,
                    startingCreditSupply + /// the rest goes to profit, which is interpolated over the period
                    suppliedAmount,
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
            interest + startingCreditSupply + suppliedAmount,
            "incorrect credit supply"
        );
        assertEq(
            credit.balanceOf(userOne),
            suppliedAmount,
            "incorrect credit balance"
        );

        console.log("startingCreditSupply: ", startingCreditSupply);
        assertEq(
            rateLimitedCreditMinter.buffer(),
            rateLimitedCreditMinter.bufferCap() - startingCreditSupply,
            "incorrect buffer after repay"
        );
        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            repayTime,
            "incorrect last buffer used time"
        );
        assertEq(term.issuance(), 0, "incorrect issuance, should be 0");
    }
}
