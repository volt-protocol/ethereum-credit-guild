// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockCoreRef} from "@test/mock/MockCoreRef.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";

contract UnitTestCoreRef is Test {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    MockCoreRef private coreRef;
    MockERC20 private token;

    event CoreUpdate(address indexed oldCore, address indexed newCore);

    function revertMe() external pure {
        revert();
    }

    function setUp() public {
        core = new Core();
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        coreRef = new MockCoreRef(address(core));

        token = new MockERC20();

        vm.label(address(core), "core");
        vm.label(address(coreRef), "coreRef");
        vm.label(address(token), "token");
    }

    function testSetup() public {
        assertEq(address(coreRef.core()), address(core));
    }

    function testSetCoreGovSucceeds() public {
        Core core2 = new Core();
        vm.prank(governor);

        vm.expectEmit(true, true, false, true, address(coreRef));
        emit CoreUpdate(address(core), address(core2));

        coreRef.setCore(address(core2));

        assertEq(address(coreRef.core()), address(core2));
    }

    function testSetCoreAddressZeroGovSucceedsBricksContract() public {
        vm.prank(governor);
        vm.expectEmit(true, true, false, true, address(coreRef));
        emit CoreUpdate(address(core), address(0));

        coreRef.setCore(address(0));

        assertEq(address(coreRef.core()), address(0));

        // cannot check role because core doesn't respond 
        vm.expectRevert();
        coreRef.pause();
    }

    function testSetCoreNonGovFails() public {
        vm.expectRevert("UNAUTHORIZED");
        coreRef.setCore(address(0));

        assertEq(address(coreRef.core()), address(core));
    }

    function testEmergencyActionFailsNonGovernor() public {
        MockCoreRef.Call[] memory calls = new MockCoreRef.Call[](1);
        calls[0].callData = abi.encodeWithSignature(
            "transfer(address,uint256)",
            address(this),
            100
        );
        calls[0].target = address(token);

        vm.expectRevert("UNAUTHORIZED");
        coreRef.emergencyAction(calls);
    }

    function testEmergencyActionSucceedsGovernor(uint256 mintAmount) public {
        MockCoreRef.Call[] memory calls = new MockCoreRef.Call[](1);
        calls[0].callData = abi.encodeWithSignature(
            "mint(address,uint256)",
            address(this),
            mintAmount
        );
        calls[0].target = address(token);

        vm.prank(governor);
        coreRef.emergencyAction(calls);

        assertEq(token.balanceOf(address(this)), mintAmount);
    }

    function testEmergencyActionSucceedsGovernorSendEth(
        uint128 sendAmount
    ) public {
        uint256 startingEthBalance = address(this).balance;

        MockCoreRef.Call[] memory calls = new MockCoreRef.Call[](1);
        calls[0].target = address(this);
        calls[0].value = sendAmount;
        vm.deal(address(coreRef), sendAmount);

        vm.prank(governor);
        coreRef.emergencyAction(calls);

        uint256 endingEthBalance = address(this).balance;

        assertEq(endingEthBalance - startingEthBalance, sendAmount);
        assertEq(address(coreRef).balance, 0);
    }

    function testEmergencyActionSucceedsGovernorSendsEth(
        uint128 sendAmount
    ) public {
        MockCoreRef.Call[] memory calls = new MockCoreRef.Call[](1);
        calls[0].target = governor;
        calls[0].value = sendAmount;
        vm.deal(governor, sendAmount);

        vm.prank(governor);
        coreRef.emergencyAction{value: sendAmount}(calls);

        uint256 endingEthBalance = governor.balance;

        assertEq(endingEthBalance, sendAmount);
        assertEq(address(coreRef).balance, 0);
    }

    function testEmergencyActionReverting() public {
        MockCoreRef.Call[] memory calls = new MockCoreRef.Call[](1);
        calls[0].target = address(this);
        calls[0].value = 0;
        calls[0].callData = abi.encodeWithSignature("revertMe()");

        vm.prank(governor);
        vm.expectRevert("CoreRef: underlying call reverted");
        coreRef.emergencyAction(calls);
    }

    function testPausableSucceedsGuardian() public {
        assertTrue(!coreRef.paused());
        vm.prank(guardian);
        coreRef.pause();
        assertTrue(coreRef.paused());
        vm.prank(guardian);
        coreRef.unpause();
        assertTrue(!coreRef.paused());
    }

    function testPauseFailsNonGuardian() public {
        vm.expectRevert("UNAUTHORIZED");
        coreRef.pause();
    }

    receive() external payable {}
}
