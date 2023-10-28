// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@forge-std/Test.sol";

import {NameLib as strings} from "@test/utils/NameLib.sol";
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

    /// TODO
    function testCreditStakerGainsOnLoanRepayWithInterest() public {}

    /// TODO
    function testCreditStakerSlashOnBadDebtLossEvent() public {}

    //// Helper functions

    function _testSetMintRatio(uint256 mintRatio) private {
        vm.prank(addresses.mainnet(strings.TIMELOCK));

        surplusGuildMinter.setMintRatio(mintRatio);
        assertEq(
            surplusGuildMinter.mintRatio(),
            mintRatio,
            "incorrect mint ratio"
        );
    }

    function _testSetRewardRatio(uint256 rewardRatio) private {
        vm.prank(addresses.mainnet(strings.TIMELOCK));

        surplusGuildMinter.setRewardRatio(rewardRatio);

        assertEq(
            surplusGuildMinter.rewardRatio(),
            rewardRatio,
            "incorrect reward ratio"
        );
    }

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
}
