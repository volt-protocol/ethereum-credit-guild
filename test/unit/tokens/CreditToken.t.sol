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

        token = new CreditToken(address(core), "name", "symbol");

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
        assertEq(token.rebasingSupply(), 0);
        assertEq(token.nonRebasingSupply(), 0);
        assertEq(token.isRebasing(alice), false);
        assertEq(token.isRebasing(bob), false);
    }

    function testMint() public {
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

    function testSetMaxDelegates() public {
        assertEq(token.maxDelegates(), 0);

        // without role, reverts
        vm.expectRevert("UNAUTHORIZED");
        token.setMaxDelegates(1);

        // grant role
        vm.startPrank(governor);
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, address(this));
        vm.stopPrank();

        // set max delegates
        token.setMaxDelegates(1);
        assertEq(token.maxDelegates(), 1);
    }

    function testSetContractExceedMaxDelegates() public {
        // without role, reverts
        vm.expectRevert("UNAUTHORIZED");
        token.setContractExceedMaxDelegates(address(this), true);

        // grant role
        vm.startPrank(governor);
        core.grantRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS, address(this));
        vm.stopPrank();

        // set flag
        token.setContractExceedMaxDelegates(address(this), true);
        assertEq(token.canContractExceedMaxDelegates(address(this)), true);

        // does not work if address is an eoa
        vm.expectRevert("ERC20MultiVotes: not a smart contract");
        token.setContractExceedMaxDelegates(alice, true);
    }

    function testForceEnterRebase() public {
        // without role, reverts
        vm.expectRevert("UNAUTHORIZED");
        token.forceEnterRebase(alice);

        // grant role
        vm.startPrank(governor);
        core.grantRole(CoreRoles.CREDIT_REBASE_PARAMETERS, address(this));
        vm.stopPrank();

        // force alice to enter rebase
        token.forceEnterRebase(alice);
        assertEq(token.isRebasing(alice), true);

        // does not work if address is already rebasing
        vm.expectRevert("CreditToken: already rebasing");
        token.forceEnterRebase(alice);
    }

    function testForceExitRebase() public {
        // without role, reverts
        vm.expectRevert("UNAUTHORIZED");
        token.forceExitRebase(alice);

        // grant role
        vm.startPrank(governor);
        core.grantRole(CoreRoles.CREDIT_REBASE_PARAMETERS, address(this));
        vm.stopPrank();

        // force alice to enter rebase
        token.forceEnterRebase(alice);
        assertEq(token.isRebasing(alice), true);

        // force alic to exit rebase
        token.forceExitRebase(alice);
        assertEq(token.isRebasing(alice), false);

        // does not work if address is already rebasing
        vm.expectRevert("CreditToken: not rebasing");
        token.forceExitRebase(alice);
    }

    function testDistribute() public {
        // create/grant role
        vm.startPrank(governor);
        core.createRole(CoreRoles.CREDIT_MINTER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.CREDIT_REBASE_PARAMETERS, address(this));
        vm.stopPrank();

        // initial state
        token.mint(alice, 1000e18);
        token.mint(bob, 1000e18);
        token.forceEnterRebase(alice);

        assertEq(token.totalSupply(), 2000e18);
        assertEq(token.rebasingSupply(), 1000e18);
        assertEq(token.nonRebasingSupply(), 1000e18);
        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(bob), 1000e18);

        // distribute (1)
        token.mint(address(this), 1000e18);
        token.approve(address(token), 1000e18);
        token.distribute(1000e18);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        // after distribute (1)
        assertEq(token.totalSupply(), 3000e18);
        assertEq(token.rebasingSupply(), 2000e18);
        assertEq(token.nonRebasingSupply(), 1000e18);
        assertEq(token.balanceOf(alice), 2000e18);
        assertEq(token.balanceOf(bob), 1000e18);

        // bob enters rebase
        token.forceEnterRebase(bob);

        // distribute (2)
        token.mint(address(this), 3000e18);
        token.approve(address(token), 3000e18);
        token.distribute(3000e18);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        // after distribute (2)
        assertEq(token.totalSupply(), 6000e18);
        assertEq(token.rebasingSupply(), 6000e18);
        assertEq(token.nonRebasingSupply(), 0);
        assertEq(token.balanceOf(alice), 4000e18);
        assertEq(token.balanceOf(bob), 2000e18);
    }
}
