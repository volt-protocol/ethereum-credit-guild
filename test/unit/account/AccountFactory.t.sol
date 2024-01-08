// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {AccountImplementation} from "@src/account/AccountImplementation.sol";
import {AccountFactory} from "@src/account/AccountFactory.sol";

contract UnitTestAccountFactory is Test {
    AccountFactory public factory;

    address factoryOwner = address(10101);

    function setUp() public {
        vm.prank(factoryOwner);
        factory = new AccountFactory();
    }

    function testSetup(address target, bytes4 functionSelector) public {
        // factory deployer must be the owner
        assertEq(factory.owner(), factoryOwner);

        // allowedCalls should return false for any calls by default
        // this is a fuzz test so it does not test every possibilities but still...
        assertEq(factory.allowedCalls(target, functionSelector), false);
    }

    function testAllowImplementationShouldRevertIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        factory.allowImplementation(address(1), true);
    }

    function testAllowCallShouldRevertIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        factory.allowCall(address(1), 0x01020304, true);
    }
    
    function testAllowImplementationAsOwnerShouldWork(address a1, address a2) public {
        vm.assume(a1 != a2);
        vm.startPrank(factoryOwner);
        assertEq(factory.implementations(a1), false);
        assertEq(factory.implementations(a2), false);
        factory.allowImplementation(a1, true);
        factory.allowImplementation(a2, true);
        assertEq(factory.implementations(a1), true);
        assertEq(factory.implementations(a2), true);
        factory.allowImplementation(a2, false);
        assertEq(factory.implementations(a1), true);
        assertEq(factory.implementations(a2), false);
        vm.stopPrank();
    }
    
    function testAllowCallAsOwnerShouldWork(address a1, bytes4 s1, address a2, bytes4 s2) public {
        vm.assume(a1 != a2);
        vm.startPrank(factoryOwner);
        assertEq(factory.allowedCalls(a1, s1), false);
        assertEq(factory.allowedCalls(a2, s2), false);
        factory.allowCall(a1, s1, true);
        factory.allowCall(a2, s2, true);
        assertEq(factory.allowedCalls(a1, s1), true);
        assertEq(factory.allowedCalls(a2, s2), true);
        factory.allowCall(a2, s2, false);
        assertEq(factory.allowedCalls(a1, s1), true);
        assertEq(factory.allowedCalls(a2, s2), false);
        vm.stopPrank();
    }

    function testCreateAccountWithoutImplementation(address a) public {
        vm.expectRevert("AccountFactory: invalid implementation");
        factory.createAccount(a);
    }
    
    function testCreateAccount() public {
        vm.prank(factoryOwner);
        address implementation = address(new AccountImplementation());
        vm.prank(factoryOwner);
        factory.allowImplementation(implementation, true);

        address accountCreated = factory.createAccount(implementation);

        // validate account has been created
        assertEq(factory.created(accountCreated), block.timestamp);

        assertTrue(accountCreated != address(0));
    }
}