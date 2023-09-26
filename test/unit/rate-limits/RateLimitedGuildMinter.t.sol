// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

contract RateLimitedGuildMinterUnitTest is Test {
    RateLimitedMinter public rlgm;
    MockERC20 private token;
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    address constant alice = address(0x616c696365);

    uint256 MAX_RATE_LIMIT_PER_SECOND = 10 ether;
    uint128 RATE_LIMIT_PER_SECOND = 10 ether;
    uint128 BUFFER_CAP = 10_000_000 ether;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        token = new MockERC20();
        rlgm = new RateLimitedMinter(
            address(core),
            address(token),
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            MAX_RATE_LIMIT_PER_SECOND,
            RATE_LIMIT_PER_SECOND,
            BUFFER_CAP
        );

        vm.label(address(token), "token");
        vm.label(address(core), "core");
        vm.label(address(rlgm), "rlgm");
        vm.label(address(this), "test");
    }

    function testInitialState() public {
        assertEq(address(rlgm.core()), address(core));
        assertEq(rlgm.token(), address(token));
    }

    function testMint() public {
        // without role, minting reverts
        vm.expectRevert("UNAUTHORIZED");
        rlgm.mint(address(this), 100);

        // create/grant role
        vm.startPrank(governor);
        core.createRole(
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            CoreRoles.GOVERNOR
        );
        core.grantRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, address(this));
        vm.stopPrank();

        // mint tokens for alice
        rlgm.mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);
        assertEq(rlgm.buffer(), BUFFER_CAP - 100);
    }

    function testReplenishBuffer() public {
        // without role, replenishBuffer reverts
        vm.expectRevert("UNAUTHORIZED");
        rlgm.replenishBuffer(100);

        // create/grant role
        vm.startPrank(governor);
        core.createRole(
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            CoreRoles.GOVERNOR
        );
        core.grantRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, address(this));
        vm.stopPrank();

        // mint all the available buffer for alice
        rlgm.mint(alice, rlgm.buffer());
        assertEq(token.balanceOf(alice), BUFFER_CAP);

        // trying to mint more reverts
        vm.expectRevert("RateLimited: no rate limit buffer");
        rlgm.mint(alice, 100);

        // replenish buffer
        rlgm.replenishBuffer(100);
        assertEq(rlgm.buffer(), 100);

        // can mint the replenished amount
        rlgm.mint(alice, 100);
    }

    function testMintPausable() public {
        // create/grant role
        vm.startPrank(governor);
        core.createRole(
            CoreRoles.RATE_LIMITED_GUILD_MINTER,
            CoreRoles.GOVERNOR
        );
        core.grantRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, address(this));
        vm.stopPrank();
        vm.prank(guardian);
        rlgm.pause();

        // minting reverts because the contract is paused
        vm.expectRevert("Pausable: paused");
        rlgm.mint(alice, 100);
    }
}
