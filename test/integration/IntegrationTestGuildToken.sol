// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@forge-std/Test.sol";

import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestGuildToken is PostProposalCheckFixture {
    function testGuildTokenTransferPaused() public {
        assertFalse(guild.transferable());
    }

    function testGuildTokenTransferFails() public {
        vm.expectRevert("GuildToken: transfers disabled");
        guild.transfer(address(this), 1);
    }

    function _mintGuildToUser(address to, uint96 amount) private {
        uint256 startingBalance = guild.balanceOf(to);

        vm.prank(address(rateLimitedGuildMinter));
        guild.mint(to, amount);

        assertEq(guild.balanceOf(to), startingBalance + amount);
    }

    function testStakeOnGauge() public {
        address to = address(123456);
        uint96 amount = 12345678910111213141516;

        uint256 totalWeightBefore = guild.totalWeight();
        _stakeOnGauge(to, amount);
        uint256 totalWeightAfter = guild.totalWeight();

        assertEq(
            totalWeightAfter - totalWeightBefore,
            amount,
            "total weight ne guild amt"
        );
    }

    function _stakeOnGauge(address to, uint96 amount) private {
        _mintGuildToUser(to, amount);

        uint256 guildAmount = guild.balanceOf(to);
        uint256 startingWeight = guild.totalWeight();

        vm.prank(to);
        guild.incrementGauge(address(term), guildAmount);

        assertEq(
            guild.userGauges(to)[0],
            address(term),
            "user gauges incorrect"
        );
        assertEq(guild.numUserGauges(to), 1, "num user gauges incorrect");
        assertEq(guild.userUnusedWeight(to), 0, "user unused weight incorrect");
        assertEq(
            guild.totalWeight(),
            startingWeight + guildAmount,
            "total weight incorrect"
        ); /// total weight increased and is equal to user balance
        assertEq(
            guild.totalTypeWeight(guild.gaugeType(address(term))),
            startingWeight + guildAmount,
            "total type weight incorrect"
        ); /// total type weight increased
        assertTrue(
            guild.isUserGauge(to, address(term)),
            "is user gauge incorrect"
        );
    }

    function testRemoveExistingGaugeSucceeds() public {
        uint256 startingGaugeWeight = guild.getGaugeWeight(address(term));
        uint256 startingTotalWeight = guild.totalWeight();

        vm.prank(getAddr("DAO_TIMELOCK"));
        guild.removeGauge(address(term));

        uint256 endingTotalWeight = guild.totalWeight();
        uint256 endingGaugeWeight = guild.getGaugeWeight(address(term));

        assertEq(startingGaugeWeight, endingGaugeWeight);
        assertEq(startingTotalWeight, endingTotalWeight + startingGaugeWeight); /// total weight decremented
        assertTrue(guild.isDeprecatedGauge(address(term)));
        assertFalse(guild.isGauge(address(term)));
    }

    function testRemoveExistingStakedGaugeSucceeds() public {
        address userA = address(0xaaaaaa);
        address userB = address(0xbbbbbb);
        address userC = address(0xcccccc);

        uint96 stakeAmount = uint96(rateLimitedGuildMinter.buffer() / 3);
        uint256 totalSupplyBefore = guild.totalSupply();

        _stakeOnGauge(userA, stakeAmount);
        _stakeOnGauge(userB, stakeAmount);
        _stakeOnGauge(userC, stakeAmount);

        testRemoveExistingGaugeSucceeds();

        _testBalanceAndWeightAssertion(userA, stakeAmount);
        _testBalanceAndWeightAssertion(userB, stakeAmount);
        _testBalanceAndWeightAssertion(userC, stakeAmount);

        assertFalse(guild.isGauge(address(term)), "gauge undeprecated");
        assertTrue(
            guild.isDeprecatedGauge(address(term)),
            "gauge not deprecated"
        );
        assertEq(
            guild.totalSupply(),
            totalSupplyBefore + stakeAmount * 3,
            "incorrect total supply after removing gauge"
        );
    }

    function _testBalanceAndWeightAssertion(
        address user,
        uint96 amount
    ) private {
        assertEq(guild.balanceOf(user), amount, "user balance incorrect");
        assertEq(
            guild.userUnusedWeight(user),
            0,
            "user unused weight incorrect"
        ); /// fully staked
        assertEq(
            guild.getUserGaugeWeight(user, address(term)),
            amount,
            "user gauge weight incorrect"
        ); /// still staked to the term
        assertEq(guild.getUserWeight(user), amount, "user weight incorrect"); /// still staked to the term
    }
}
