// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";

contract CreditTokenUnitTest is Test {
    address private governor = address(1);
    Core private core;
    CreditToken token;
    address constant alice = address(0x616c696365);
    address constant bob = address(0xB0B);

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        token = new CreditToken(address(core));

        // labels
        vm.label(address(core), "core");
        vm.label(address(token), "token");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }

    function testInitialState() public {
        assertEq(address(token.core()), address(core));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testMintAccessControl() public {
        // without role, mint reverts
        vm.expectRevert("UNAUTHORIZED");
        token.mint(alice, 100);

        // create/grant role
        vm.startPrank(governor);
        core.createRole(CoreRoles.CREDIT_MINTER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        vm.stopPrank();

        // mint tokens for alice
        token.mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), 100);

        // alice transfers to bob
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100);
        assertEq(token.totalSupply(), 100);
    }
}
