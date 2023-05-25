// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";

contract GuildTokenUnitTest is Test {
    address private governor = address(1);
    Core private core;
    GuildToken token;
    address constant alice = address(0x616c696365);
    address constant bob = address(0xB0B);
    address constant gauge1 = address(0xDEAD);
    address constant gauge2 = address(0xBEEF);

    uint32 constant _CYCLE_LENGTH = 1 hours;
    uint32 constant _FREEZE_PERIOD = 10 minutes;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        token = new GuildToken(address(core), _CYCLE_LENGTH, _FREEZE_PERIOD);

        // labels
        vm.label(address(core), "core");
        vm.label(address(token), "token");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(gauge1, "gauge1");
        vm.label(gauge2, "gauge2");
    }

    /*///////////////////////////////////////////////////////////////
                        TEST INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function testInitialState() public {
        assertEq(address(token.core()), address(core));
        assertEq(token.transferable(), false);
    }

    /*///////////////////////////////////////////////////////////////
                        TEST MINT/BURN
    //////////////////////////////////////////////////////////////*/

    function testCanMintAndBurnWithoutTransfersEnabled() public {
        // grant minter role to self
        vm.startPrank(governor);
        core.createRole(CoreRoles.GUILD_MINTER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        vm.stopPrank();

        assertEq(token.totalSupply(), 0);

        // mint to self
        token.mint(address(this), 100e18);
        assertEq(token.balanceOf(address(this)), 100e18);
        assertEq(token.totalSupply(), 100e18);

        // burn from self
        token.burn(100e18);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), 0);
    }

    /*///////////////////////////////////////////////////////////////
                        TRANSFERABILITY
    //////////////////////////////////////////////////////////////*/

    function testEnableTransfer() public {
        vm.expectRevert("UNAUTHORIZED");
        token.enableTransfer();
        vm.prank(governor);
        token.enableTransfer();
        assertEq(token.transferable(), true);
    }

    function testRevertTransferIfNotEnabled() public {
        // grant minter role to self
        vm.startPrank(governor);
        core.createRole(CoreRoles.GUILD_MINTER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        vm.stopPrank();

        // revert because transfers are not enabled
        token.mint(alice, 100e18);
        vm.expectRevert("GuildToken: transfers disabled");
        vm.prank(alice);
        token.transfer(bob, 100e18);

        // enable transfers & transfer
        vm.prank(governor);
        token.enableTransfer();
        vm.prank(alice);
        token.transfer(bob, 100e18);

        // check the tokens moved
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100e18);
    }

    function testRevertTransferFromIfNotEnabled() public {
        // grant minter role to self
        vm.startPrank(governor);
        core.createRole(CoreRoles.GUILD_MINTER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        vm.stopPrank();

        // revert because transfers are not enabled
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 100e18);
        vm.expectRevert("GuildToken: transfers disabled");
        vm.prank(bob);
        token.transferFrom(alice, bob, 100e18);

        // enable transfers & transfer
        vm.prank(governor);
        token.enableTransfer();
        vm.prank(bob);
        token.transferFrom(alice, bob, 100e18);

        // check the tokens moved
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100e18);
    }

    /*///////////////////////////////////////////////////////////////
                        GAUGE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function testAddGauge() public {
        // revert because user doesn't have role
        vm.expectRevert("UNAUTHORIZED");
        token.addGauge(gauge1);

        // grant role to test contract
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_ADD, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        vm.stopPrank();

        // successful call & check
        token.addGauge(gauge1);
        assertEq(token.isGauge(gauge1), true);
    }

    function testRemoveGauge() public {
        // add gauge
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_ADD, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        vm.stopPrank();
        token.addGauge(gauge1);
        assertEq(token.isGauge(gauge1), true);

        // revert because user doesn't have role
        vm.expectRevert("UNAUTHORIZED");
        token.removeGauge(gauge1);

        // grant role to test contract
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_REMOVE, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        vm.stopPrank();

        // successful call & check
        token.removeGauge(gauge1);
        assertEq(token.isGauge(gauge1), false);
    }

    function testSetMaxGauges() public {
        // revert because user doesn't have role
        vm.expectRevert("UNAUTHORIZED");
        token.setMaxGauges(42);

        // grant role to test contract
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_PARAMETERS, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        vm.stopPrank();

        // successful call & check
        token.setMaxGauges(42);
        assertEq(token.maxGauges(), 42);
    }

    function testSetCanExceedMaxGauges() public {
        // revert because user doesn't have role
        vm.expectRevert("UNAUTHORIZED");
        token.setCanExceedMaxGauges(alice, true);
        assertEq(token.canExceedMaxGauges(alice), false);

        // grant role to test contract
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_PARAMETERS, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        vm.stopPrank();

        // successful call & check
        token.setCanExceedMaxGauges(address(this), true);
        assertEq(token.canExceedMaxGauges(address(this)), true);
    }

    /*///////////////////////////////////////////////////////////////
                        LOSS MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function testNotifyPnL() public {
        assertEq(token.lastGaugeLoss(gauge1), 0);
        assertEq(token.totalPnL(), 0);
        assertEq(token.gaugePnL(gauge1), 0);

        // revert because user doesn't have role
        vm.expectRevert("UNAUTHORIZED");
        token.notifyPnL(gauge1, 0);

        // grant roles to test contract
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_PNL_NOTIFIER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        vm.stopPrank();

        // successful call & check
        token.notifyPnL(gauge1, -100);
        assertEq(token.lastGaugeLoss(gauge1), block.timestamp);
        assertEq(token.totalPnL(), -100);
        assertEq(token.gaugePnL(gauge1), -100);

        // successful call & check
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        token.notifyPnL(gauge1, 200);
        assertEq(token.lastGaugeLoss(gauge1), block.timestamp - 13);
        assertEq(token.totalPnL(), 100);
        assertEq(token.gaugePnL(gauge1), 100);
    }

    function _setupAliceLossInGauge1() internal {
        // grant roles to test contract
        vm.startPrank(governor);
        core.createRole(CoreRoles.GUILD_MINTER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.createRole(CoreRoles.GAUGE_ADD, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.createRole(CoreRoles.GAUGE_PARAMETERS, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.createRole(CoreRoles.GAUGE_PNL_NOTIFIER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        vm.stopPrank();

        // setup
        token.setMaxGauges(2);
        token.addGauge(gauge1);
        token.addGauge(gauge2);
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.incrementGauge(gauge1, 40e18);
        token.incrementGauge(gauge2, 40e18);
        vm.stopPrank();
        assertEq(token.userUnusedWeight(alice), 20e18);
        assertEq(token.getUserWeight(alice), 80e18);

        // loss in gauge 1
        token.notifyPnL(gauge1, -100);
    }

    function testApplyGaugeLoss() public {
        // revert if the gauge has no reported loss yet
        vm.expectRevert("GuildToken: no loss to apply");
        token.applyGaugeLoss(gauge1, alice);

        _setupAliceLossInGauge1();

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);
        assertEq(token.lastGaugeLossApplied(gauge1, alice), block.timestamp);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.userUnusedWeight(alice), 20e18);
        assertEq(token.getUserWeight(alice), 40e18);
        assertEq(token.getUserGaugeWeight(alice, gauge1), 0);
        assertEq(token.getUserGaugeWeight(alice, gauge2), 40e18);

        // can decrement gauge weights again since loss has been applied
        vm.prank(alice);
        token.decrementGauge(gauge2, 40e18);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.userUnusedWeight(alice), 60e18);
        assertEq(token.getUserWeight(alice), 0);
    }

    function testCannotTransferIfLossUnapplied() public {
        _setupAliceLossInGauge1();

        // enable transfers
        vm.prank(governor);
        token.enableTransfer();

        // alice cannot transfer tokens because of unrealized loss
        vm.expectRevert("GuildToken: pending loss");
        vm.prank(alice);
        token.transfer(bob, 60e18);

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);

        // can transfer
        vm.prank(alice);
        token.transfer(bob, 60e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 60e18);
    }

    function testCannotTransferFromIfLossUnapplied() public {
        _setupAliceLossInGauge1();

        // enable transfers
        vm.prank(governor);
        token.enableTransfer();

        // alice approve bob to transferFrom
        vm.prank(alice);
        token.approve(bob, 100e18);

        // bob cannot transferFrom alice because of unrealized loss
        vm.prank(bob);
        vm.expectRevert("GuildToken: pending loss");
        token.transferFrom(alice, bob, 100e18);

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);

        // bob can transferFrom the unslashed tokens
        vm.prank(bob);
        token.transferFrom(alice, bob, 60e18);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 60e18);
    }

    function testCannotIncrementGaugeIfLossUnapplied() public {
        _setupAliceLossInGauge1();

        // can increment gauges that haven't been affected by the loss
        vm.prank(alice);
        token.incrementGauge(gauge2, 20e18);

        // cannot increment gauges that have been affected by the loss
        vm.prank(alice);
        vm.expectRevert("GuildToken: pending loss");
        token.incrementGauge(gauge1, 20e18);

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);

        assertEq(token.balanceOf(alice), 60e18);
    }

    function testCannotIncrementGaugesIfLossUnapplied() public {
        _setupAliceLossInGauge1();

        // can increment gauges that haven't been affected by the loss
        vm.prank(alice);
        address[] memory gaugesToIncrement1 = new address[](1);
        gaugesToIncrement1[0] = gauge2;
        uint112[] memory amountsToIncrement1 = new uint112[](1);
        amountsToIncrement1[0] = 20e18;
        token.incrementGauges(gaugesToIncrement1, amountsToIncrement1);

        // cannot increment gauges that have been affected by the loss
        address[] memory gaugesToIncrement2 = new address[](1);
        gaugesToIncrement2[0] = gauge1;
        uint112[] memory amountsToIncrement2 = new uint112[](1);
        amountsToIncrement2[0] = 20e18;
        vm.prank(alice);
        vm.expectRevert("GuildToken: pending loss");
        token.incrementGauges(gaugesToIncrement2, amountsToIncrement2);

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);

        assertEq(token.balanceOf(alice), 60e18);
    }

    function testCannotDecrementGaugeIfLossUnapplied() public {
        _setupAliceLossInGauge1();

        // can decrement gauges that haven't been affected by the loss
        vm.prank(alice);
        token.decrementGauge(gauge2, 40e18);

        // cannot decrement gauges that have been affected by the loss
        vm.prank(alice);
        vm.expectRevert("GuildToken: pending loss");
        token.decrementGauge(gauge1, 40e18);

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);

        assertEq(token.balanceOf(alice), 60e18);
    }

    function testCannotDecrementGaugesIfLossUnapplied() public {
        _setupAliceLossInGauge1();

        // can decrement gauges that haven't been affected by the loss
        vm.prank(alice);
        address[] memory gaugesToDecrement1 = new address[](1);
        gaugesToDecrement1[0] = gauge2;
        uint112[] memory amountsToDecrement1 = new uint112[](1);
        amountsToDecrement1[0] = 40e18;
        token.decrementGauges(gaugesToDecrement1, amountsToDecrement1);

        // cannot decrement gauges that have been affected by the loss
        address[] memory gaugesToDecrement2 = new address[](1);
        gaugesToDecrement2[0] = gauge1;
        uint112[] memory amountsToDecrement2 = new uint112[](1);
        amountsToDecrement2[0] = 40e18;
        vm.prank(alice);
        vm.expectRevert("GuildToken: pending loss");
        token.decrementGauges(gaugesToDecrement2, amountsToDecrement2);

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);

        assertEq(token.balanceOf(alice), 60e18);
    }
}
