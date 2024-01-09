// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {AccountImplementation} from "@src/account/AccountImplementation.sol";
import {AccountFactory} from "@src/account/AccountFactory.sol";
import {MockERC20} from "../../mock/MockERC20.sol";

contract RejectingReceiver {
    receive() external payable {
        revert("RejectingReceiver: rejecting ETH");
    }
}

contract UnitTestAccountImplementation is Test {
    AccountFactory public factory;
    address factoryOwner = address(10101);
    address alice = address(1);
    address bob = address(2);
    address allowedTarget = address(101);
    bytes4 allowedSig1 = bytes4(0x68ad3191); // superfunction(address,uint256)
    bytes4 allowedSig2 = bytes4(0x82c52709); // betterfunction(address,address)

    address validImplementation;
    AccountImplementation aliceAccount;

    MockERC20 mockToken;

    function setUp() public {
        // set up a factory and an implementation
        vm.startPrank(factoryOwner);
        factory = new AccountFactory();
        validImplementation = address(new AccountImplementation());
        factory.allowImplementation(validImplementation, true);
        factory.allowCall(allowedTarget, allowedSig1, true);
        factory.allowCall(allowedTarget, allowedSig2, true);
        vm.stopPrank();

        // set up an account for alice
        vm.prank(alice);
        aliceAccount = AccountImplementation(factory.createAccount(validImplementation));

        // set up a mockerc20
        mockToken = new MockERC20();
    }

    function testInit() public {
        assertEq(factory.allowedCalls(allowedTarget, allowedSig1), true);
        assertEq(factory.allowedCalls(allowedTarget, allowedSig2), true);
        assertTrue(validImplementation != address(0));
        assertTrue(address(aliceAccount) != address(0));
        assertEq(alice, aliceAccount.owner());
    }

    function testCallInitializeShouldFail() public {
        vm.expectRevert("AccountImplementation: already initialized");
        aliceAccount.initialize(bob);
    }

    function testRenounceOwnershipShouldFailIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(bob);
        aliceAccount.renounceOwnership();
    }

    function testRenounceOwnershipShouldFailEvenifOwner() public {
        vm.expectRevert("AccountImplementation: cannot renounce ownership");
        vm.prank(alice);
        aliceAccount.renounceOwnership();
    }

    function testWithdrawShouldFailIfNotOwner() public {
        mockToken.mint(address(aliceAccount), 1000e18);
        assertEq(mockToken.balanceOf(address(aliceAccount)), 1000e18);

        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        aliceAccount.withdraw(address(mockToken), 1000e18);
    }

    function testWithdrawShouldWithdrawTheAmountRequested() public {
        mockToken.mint(address(aliceAccount), 1000e18);
        assertEq(mockToken.balanceOf(address(aliceAccount)), 1000e18);
        assertEq(mockToken.balanceOf(alice), 0);

        vm.prank(alice);
        aliceAccount.withdraw(address(mockToken), 250e18);
        assertEq(mockToken.balanceOf(address(aliceAccount)), 750e18);
        assertEq(mockToken.balanceOf(alice), 250e18);
    }

    function testWithdrawEthShouldFailIfNotOwner() public {
        // try to withdraw eth as bob
        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        aliceAccount.withdrawEth();
    }

    function testWithdrawEthShouldFailIfNoBalance() public {
        vm.prank(alice);
        vm.expectRevert("AccountImplementation: no ETH to withdraw");
        aliceAccount.withdrawEth();
    }

    function testWithdrawFailShouldRevert() public {
        RejectingReceiver receiver = new RejectingReceiver();
        vm.prank(address(receiver));
        address createdAccount = factory.createAccount(validImplementation);
        assertEq(createdAccount.balance, 0);
        assertEq(AccountImplementation(createdAccount).owner(), address(receiver));

        vm.deal(createdAccount, 1e18);
        assertEq(createdAccount.balance, 1e18);

        vm.prank(address(receiver));
        vm.expectRevert("AccountImplementation: failed to send ETH");
        AccountImplementation(createdAccount).withdrawEth();
    }

    function testWithdrawShouldWithdrawEth() public {
        assertEq(alice.balance, 0);

        // deal 1 eth to alice account
        assertEq(address(aliceAccount).balance, 0);
        vm.deal(address(aliceAccount), 1e18);
        assertEq(address(aliceAccount).balance, 1e18);

        vm.prank(alice);
        aliceAccount.withdrawEth();
        assertEq(alice.balance, 1e18);
    }
}