// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@forge-std/Test.sol";

import {AddressLib} from "@test/proposals/AddressLib.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestGuildToken is PostProposalCheckFixture {
    function testGuildTokenTransferPaused() public {
        assertFalse(guild.transferable());
    }

    function testCorrectGauge() public {
        guild.gauges(); /// does this succeed?
        assertEq(guild.gauges()[0], address(term));
    }

    function testCorrectNumDeprecatedGauges() public {
        assertEq(guild.numDeprecatedGauges(), 0);
    }

    function testMintGuildTokenNonMinterFails() public {
        vm.expectRevert("UNAUTHORIZED");
        guild.mint(address(this), 1);
    }

    function testGuildTokenTransferFails() public {
        vm.expectRevert("GuildToken: transfers disabled");
        guild.transfer(address(this), 1);
    }

    function testMintGuildToUser(address to, uint96 amount) public {
        to = address(uint160(_bound(uint160(to), 1, type(uint160).max)));

        amount = uint96(_bound(amount, 1, rateLimitedGuildMinter.buffer())); /// can only mint buffer amt

        _mintGuildToUser(to, amount);
    }

    function _mintGuildToUser(address to, uint96 amount) private {
        uint256 startingBalance = guild.balanceOf(to);

        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(to, amount);

        assertEq(guild.balanceOf(to), startingBalance + amount);
    }

    function testStakeOnGauge(
        address to,
        uint96 amount
    ) public returns (uint256) {
        to = address(uint160(_bound(uint160(to), 1, type(uint160).max)));
        amount = uint96(_bound(amount, 1, rateLimitedGuildMinter.buffer())); /// can only stake up to buffer in guild minter

        _stakeOnGauge(to, amount);

        assertEq(guild.totalWeight(), amount, "total weight ne guild amt"); /// total weight increased and is equal to user balance

        return amount;
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

        vm.prank(AddressLib.get("DAO_TIMELOCK"));
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
            guild.totalWeight(),
            0,
            "incorrect total weight after removing gauge"
        );
        assertEq(
            guild.totalSupply(),
            stakeAmount * 3,
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

    struct StakeOnGaugeParams {
        address to;
        uint80 amount; /// bound max mint amount to ~1.2m
    }

    function testMultipleUsersStakeOnGauge(
        StakeOnGaugeParams[100] memory params
    ) external {
        /// to address is strictly monotonically increasing
        uint256 totalStaked;

        /// `to` equals address(i + 1), override `to` address passed from fuzzer
        for (uint256 i = 0; i < params.length; i++) {
            if (rateLimitedGuildMinter.buffer() == 0) {
                /// if buffer is exhausted, stop
                break;
            }

            params[i].to = address(uint160(i + 1));
            params[i].amount = uint80(
                _bound(params[i].amount, 1, rateLimitedGuildMinter.buffer())
            ); /// can only stake up to buffer in guild minter

            _stakeOnGauge(params[i].to, params[i].amount);

            totalStaked += params[i].amount;

            assertEq(
                guild.totalWeight(),
                totalStaked,
                "total weight incorrect"
            ); /// total weight increased
        }
    }
}
