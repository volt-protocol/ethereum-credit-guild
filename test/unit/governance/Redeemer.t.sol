// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {Redeemer} from "@src/governance/Redeemer.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";

contract RedeemerUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    Redeemer private redeemer;
    MockERC20 credit;
    MockERC20 guild;
    address constant alice = address(0x616c696365);
    address constant bob = address(0xB0B);

    uint256 MAX_RATE_LIMIT_PER_SECOND = 31688087814028950000; // 31.7/s with 18 decimals
    uint128 RATE_LIMIT_PER_SECOND = 9506426344208685000; // 9.5/s with 18 decimals
    uint128 BUFFER_CAP = 20_000_000e18; // 20M GUILD

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));
        credit = new MockERC20();
        guild = new MockERC20();

        address[] memory tokensRedeemed = new address[](1);
        tokensRedeemed[0] = address(credit);
        redeemer = new Redeemer(
            address(core),
            address(guild),
            tokensRedeemed,
            MAX_RATE_LIMIT_PER_SECOND,
            RATE_LIMIT_PER_SECOND,
            BUFFER_CAP
        );

        // labels
        vm.label(address(this), "test");
        vm.label(address(core), "core");
        vm.label(address(redeemer), "redeemer");
        vm.label(address(guild), "guild");
        vm.label(address(credit), "credit");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }

    function testInitialState() public {
        assertEq(address(redeemer.redeemedToken()), address(guild));
        assertEq(redeemer.tokensReceivedOnRedeem().length, 1);
        assertEq(redeemer.tokensReceivedOnRedeem()[0], address(credit));
    }

    function testPreviewRedeem() public {
        // initial situation: 1000 GUILD can claim 100 CREDIT
        guild.mint(alice, 1000);
        credit.mint(address(redeemer), 100);

        (
            uint256 base1,
            address[] memory tokens1,
            uint256[] memory amountsOut1
        ) = redeemer.previewRedeem(500);

        assertEq(base1, 1000);
        assertEq(tokens1.length, 1);
        assertEq(tokens1[0], address(credit));
        assertEq(amountsOut1.length, 1);
        assertEq(amountsOut1[0], 50);

        // more GUILD in circulation reduce the redemption price
        // here, 2000 GUILD share 100 CREDIT
        guild.mint(alice, 1000);

        (uint256 base2, , uint256[] memory amountsOut2) = redeemer
            .previewRedeem(500);

        assertEq(base2, 2000);
        assertEq(amountsOut2[0], 25);

        // more CREDIT in the redeemer increase the redemption price
        // here, 2000 GUILD share 500 CREDIT
        credit.mint(address(redeemer), 400);

        (uint256 base3, , uint256[] memory amountsOut3) = redeemer
            .previewRedeem(500);

        assertEq(base3, 2000);
        assertEq(amountsOut3[0], 125);
    }

    function testRedeemForSelf() public {
        // 1000 GUILD can claim 100 CREDIT
        guild.mint(alice, 1000);
        credit.mint(address(redeemer), 100);

        vm.startPrank(alice);
        guild.approve(address(redeemer), 1000);
        redeemer.redeem(alice, 1000);
        vm.stopPrank();

        assertEq(credit.balanceOf(address(redeemer)), 0);
        assertEq(credit.balanceOf(alice), 100);
        assertEq(credit.balanceOf(bob), 0);
        assertEq(guild.totalSupply(), 0);
    }

    function testRedeemForOther() public {
        // 1000 GUILD can claim 100 CREDIT
        guild.mint(alice, 1000);
        credit.mint(address(redeemer), 100);

        vm.startPrank(alice);
        guild.approve(address(redeemer), 1000);
        redeemer.redeem(bob, 1000);
        vm.stopPrank();

        assertEq(credit.balanceOf(address(redeemer)), 0);
        assertEq(credit.balanceOf(alice), 0);
        assertEq(credit.balanceOf(bob), 100);
        assertEq(guild.totalSupply(), 0);
    }

    function testRedeemPausable() public {
        vm.prank(guardian);
        redeemer.pause();

        // 1000 GUILD can claim 100 CREDIT
        guild.mint(alice, 1000);
        credit.mint(address(redeemer), 100);

        vm.startPrank(alice);
        guild.approve(address(redeemer), 1000);
        vm.expectRevert("Pausable: paused");
        redeemer.redeem(bob, 1000);
        vm.stopPrank();
    }

    function testRedeemRateLimit() public {
        uint256 buffer = redeemer.buffer();

        // `buffer` GUILD can claim 100 CREDIT
        guild.mint(alice, buffer * 2);
        credit.mint(address(redeemer), 100);

        vm.startPrank(alice);
        guild.approve(address(redeemer), buffer * 2);
        redeemer.redeem(bob, buffer);
        vm.stopPrank();

        assertEq(credit.balanceOf(address(redeemer)), 50);
        assertEq(guild.balanceOf(alice), buffer);
        assertEq(credit.balanceOf(alice), 0);
        assertEq(credit.balanceOf(bob), 50);
        assertEq(guild.totalSupply(), buffer);

        vm.expectRevert("RateLimited: no rate limit buffer");
        vm.prank(alice);
        redeemer.redeem(bob, buffer);

        vm.warp(block.timestamp + 3600);

        vm.expectRevert("RateLimited: rate limit hit");
        vm.prank(alice);
        redeemer.redeem(bob, buffer);
    }

    function testGovernorRecoverFunds() public {
        // 1000 GUILD can claim 100 CREDIT
        guild.mint(alice, 1000);
        credit.mint(address(redeemer), 100);

        // governor recovers the CREDIT that are on the redeemer
        vm.prank(governor);
        redeemer.withdrawAll(address(credit), address(this));
        assertEq(credit.balanceOf(address(redeemer)), 0);
        assertEq(credit.balanceOf(address(this)), 100);

        // non-governor cannot perform the call
        vm.expectRevert("UNAUTHORIZED");
        redeemer.withdrawAll(address(credit), address(this));
    }
}
