// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {PreGuildToken} from "@src/tokens/PreGuildToken.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

contract PreGuildTokenUnitTest is ECGTest {
    address constant governor = address(8974657987897);
    Core private core;
    MockERC20 private guild;
    RateLimitedMinter public rlgm;
    PreGuildToken private preGuild;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        guild = new MockERC20();
        rlgm = new RateLimitedMinter(
            address(core),
            address(guild),
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            type(uint256).max,
            uint128(0),
            uint128(TOTAL_SUPPLY)
        );
        preGuild = new PreGuildToken(address(rlgm));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUILD_MINTER, address(rlgm));
        core.grantRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, address(preGuild));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // labels
        vm.label(address(core), "core");
        vm.label(address(guild), "guild");
        vm.label(address(preGuild), "preGuild");
        vm.label(address(rlgm), "rlgm");
        vm.label(address(this), "test");
    }

    function testInitialState() public {
        assertEq(preGuild.rlgm(), address(rlgm));
        assertEq(preGuild.totalSupply(), TOTAL_SUPPLY);
        assertEq(preGuild.balanceOf(address(this)), TOTAL_SUPPLY);
        assertEq(guild.totalSupply(), 0);
        assertEq(guild.balanceOf(address(this)), 0);
    }

    function testRedeem() public {
        uint256 amount = 1_000_000e18;
        preGuild.redeem(address(this), amount);

        assertEq(preGuild.totalSupply(), TOTAL_SUPPLY - amount);
        assertEq(preGuild.balanceOf(address(this)), TOTAL_SUPPLY - amount);
        assertEq(guild.totalSupply(), amount);
        assertEq(guild.balanceOf(address(this)), amount);
        assertEq(rlgm.buffer(), TOTAL_SUPPLY - amount);
    }

    function testBurn() public {
        uint256 amount = 1_000_000e18;
        preGuild.burn(amount);

        assertEq(preGuild.totalSupply(), TOTAL_SUPPLY - amount);
        assertEq(preGuild.balanceOf(address(this)), TOTAL_SUPPLY - amount);
        assertEq(guild.totalSupply(), 0);
        assertEq(guild.balanceOf(address(this)), 0);
    }
}
