// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {MockLendingTerm} from "@test/mock/MockLendingTerm.sol";

contract GuildTokenUnitTest is Test {
    address private governor = address(1);
    Core private core;
    ProfitManager private profitManager;
    CreditToken credit;
    GuildToken token;
    address constant alice = address(0x616c696365);
    address constant bob = address(0xB0B);
    address gauge1;
    address gauge2;
    address gauge3;

    uint256 public issuance; // for mocked behavior

    // debt ceiling with 0% tolerance
    function debtCeiling(int256 deltaGaugeWeight) external returns (uint256) {
        uint256 gaugeWeight = token.getGaugeWeight(address(this));
        uint256 gaugeType = token.gaugeType(address(this));
        uint256 totalWeight = token.totalTypeWeight(gaugeType);
        uint256 borrowSupply = credit.totalSupply(); // simplify
        uint256 gaugeWeightWithDelta = uint256(int256(gaugeWeight) + deltaGaugeWeight);
        return borrowSupply * gaugeWeightWithDelta / totalWeight;
    }

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();
        profitManager = new ProfitManager(address(core));
        credit = new CreditToken(address(core), "name", "symbol");
        token = new GuildToken(address(core), address(profitManager));
        profitManager.initializeReferences(address(credit), address(token), address(0));
        gauge1 = address(new MockLendingTerm(address(core)));
        gauge2 = address(new MockLendingTerm(address(core)));
        gauge3 = address(new MockLendingTerm(address(core)));

        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(token), "token");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(gauge1, "gauge1");
        vm.label(gauge2, "gauge2");
        vm.label(gauge3, "gauge3");

        // non-zero CREDIT circulating (for notify gauge losses)
        credit.mint(address(this), 100e18);
        credit.enterRebase();
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
                        DELEGATION
    //////////////////////////////////////////////////////////////*/

    function testSetMaxDelegates() public {
        assertEq(token.maxDelegates(), 0);

        // without role, reverts
        vm.expectRevert("UNAUTHORIZED");
        token.setMaxDelegates(1);

        // grant role
        vm.startPrank(governor);
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, address(this));
        vm.stopPrank();

        // set max delegates
        token.setMaxDelegates(1);
        assertEq(token.maxDelegates(), 1);
    }

    function testSetProfitManager() public {
        assertEq(token.profitManager(), address(profitManager));

        // without role, reverts
        vm.expectRevert("UNAUTHORIZED");
        token.setProfitManager(address(this));

        // with role, can set profitManager reference
        vm.startPrank(governor);
        token.setProfitManager(address(this));
        assertEq(token.profitManager(), address(this));
    }

    function testSetContractExceedMaxDelegates() public {
        // without role, reverts
        vm.expectRevert("UNAUTHORIZED");
        token.setContractExceedMaxDelegates(address(this), true);

        // grant role
        vm.startPrank(governor);
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, address(this));
        vm.stopPrank();

        // set flag
        token.setContractExceedMaxDelegates(address(this), true);
        assertEq(token.canContractExceedMaxDelegates(address(this)), true);

        // does not work if address is an eoa
        vm.expectRevert("ERC20MultiVotes: not a smart contract");
        token.setContractExceedMaxDelegates(alice, true);
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
        token.addGauge(1, gauge1);

        // grant role to test contract
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_ADD, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        vm.stopPrank();

        // successful call & check
        token.addGauge(1, gauge1);
        assertEq(token.isGauge(gauge1), true);
    }

    function testRemoveGauge() public {
        // add gauge
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_ADD, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        vm.stopPrank();
        token.addGauge(1, gauge1);
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

    function testNotifyPnLLastGaugeLoss() public {
        assertEq(token.lastGaugeLoss(gauge1), 0);

        // revert because user doesn't have role
        vm.expectRevert("UNAUTHORIZED");
        profitManager.notifyPnL(gauge1, 0);

        // grant roles to test contract
        vm.startPrank(governor);
        core.createRole(CoreRoles.GAUGE_PNL_NOTIFIER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        vm.stopPrank();

        // successful call & check
        profitManager.notifyPnL(gauge1, -100);
        assertEq(token.lastGaugeLoss(gauge1), block.timestamp);

        // successful call & check
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        credit.mint(address(profitManager), 200);
        profitManager.notifyPnL(gauge1, 200);
        assertEq(token.lastGaugeLoss(gauge1), block.timestamp - 13);
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
        token.setMaxGauges(3);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);
        token.addGauge(1, gauge3);
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.incrementGauge(gauge1, 40e18);
        token.incrementGauge(gauge2, 40e18);
        vm.stopPrank();
        assertEq(token.userUnusedWeight(alice), 20e18);
        assertEq(token.getUserWeight(alice), 80e18);

        // roll to next block
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        // loss in gauge 1
        profitManager.notifyPnL(gauge1, -100);
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
        uint256[] memory amountsToIncrement1 = new uint256[](1);
        amountsToIncrement1[0] = 20e18;
        token.incrementGauges(gaugesToIncrement1, amountsToIncrement1);

        // cannot increment gauges that have been affected by the loss
        address[] memory gaugesToIncrement2 = new address[](1);
        gaugesToIncrement2[0] = gauge1;
        uint256[] memory amountsToIncrement2 = new uint256[](1);
        amountsToIncrement2[0] = 20e18;
        vm.prank(alice);
        vm.expectRevert("GuildToken: pending loss");
        token.incrementGauges(gaugesToIncrement2, amountsToIncrement2);

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);

        assertEq(token.balanceOf(alice), 60e18);
    }

    function testCanIncrementGaugeIfZeroWeightAndPastLossUnapplied() public {
        _setupAliceLossInGauge1();

        // loss in gauge 3
        profitManager.notifyPnL(gauge3, -100);

        // roll to next block
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        // can increment gauge for the first time, event if it had a loss in the past
        vm.prank(alice);
        token.incrementGauge(gauge3, 20e18);
    
        assertEq(token.getUserGaugeWeight(alice, gauge1), 40e18);
        assertEq(token.getUserGaugeWeight(alice, gauge2), 40e18);
        assertEq(token.getUserGaugeWeight(alice, gauge3), 20e18);
        assertEq(token.userUnusedWeight(alice), 0);
        assertEq(token.getUserWeight(alice), 100e18);

        // the past loss does not apply to alice
        vm.expectRevert("GuildToken: no loss to apply");
        token.applyGaugeLoss(gauge3, alice);
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
        uint256[] memory amountsToDecrement1 = new uint256[](1);
        amountsToDecrement1[0] = 40e18;
        token.decrementGauges(gaugesToDecrement1, amountsToDecrement1);

        // cannot decrement gauges that have been affected by the loss
        address[] memory gaugesToDecrement2 = new address[](1);
        gaugesToDecrement2[0] = gauge1;
        uint256[] memory amountsToDecrement2 = new uint256[](1);
        amountsToDecrement2[0] = 40e18;
        vm.prank(alice);
        vm.expectRevert("GuildToken: pending loss");
        token.decrementGauges(gaugesToDecrement2, amountsToDecrement2);

        // realize loss in gauge 1
        token.applyGaugeLoss(gauge1, alice);

        assertEq(token.balanceOf(alice), 60e18);
    }

    function testDecrementGaugeDebtCeilingUsed() public {
        // grant roles to test contract
        vm.startPrank(governor);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        vm.stopPrank();

        // setup
        // 50 GUILD for alice, 50 GUILD for bob
        token.mint(alice, 150e18);
        token.mint(bob, 400e18);
        // add gauges
        token.setMaxGauges(3);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);
        token.addGauge(1, address(this));
        // 80 votes on gauge1, 40 votes on gauge2, 40 votes on this
        vm.startPrank(alice);
        token.incrementGauge(gauge1, 10e18);
        token.incrementGauge(gauge2, 10e18);
        vm.stopPrank();
        vm.startPrank(bob);
        token.incrementGauge(gauge1, 10e18);
        token.incrementGauge(address(this), 10e18);
        vm.stopPrank();

        // simulate alice borrows 100 CREDIT on this (gauge 3)
        credit.mint(alice, 100e18);
        issuance = 100e18;
        assertEq(credit.totalSupply(), 200e18);

        // gauge 3 (this) has 25% of votes, but 50% of credit issuance,
        // so nobody can decrease the votes for this gauge
        vm.expectRevert("GuildToken: debt ceiling used");
        vm.prank(bob);
        token.decrementGauge(address(this), 10e18);

        // alice now votes for gauge3 (this), so that it is still 50% of credit issuance,
        // but has 67% of votes.
        vm.prank(alice);
        token.incrementGauge(address(this), 50e18);
        // after alice increment :
        // gauge1: 20 votes
        // gauge2: 10 votes
        // gauge3 (this): 60 votes
        // now bob can decrement his gauge vote.
        vm.prank(bob);
        token.decrementGauge(address(this), 10e18);
    }
}
