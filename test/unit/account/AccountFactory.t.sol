// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {AccountImplementation} from "@src/account/AccountImplementation.sol";
import {AccountFactory} from "@src/account/AccountFactory.sol";

/// @title Test suite for the AccountFactory contract
/// @notice Implements various test cases to validate the functionality of AccountFactory contract
contract UnitTestAccountFactory is Test {
    AccountFactory public factory;

    /// @notice Address used as factory owner in tests
    address factoryOwner = address(10101);

    /// @notice Sets up the test by deploying the AccountFactory contract
    function setUp() public {
        vm.prank(factoryOwner);
        factory = new AccountFactory();
    }

    /// @notice Tests the initial state of the AccountFactory contract
    /// @param target The address to be tested with allowedCalls
    /// @param functionSelector The function selector to be tested with allowedCalls
    function testSetup(address target, bytes4 functionSelector) public {
        // factory deployer must be the owner
        assertEq(factory.owner(), factoryOwner);

        // allowedCalls should return false for any calls by default
        // this is a fuzz test so it does not test every possibilities but still...
        assertEq(factory.allowedCalls(target, functionSelector), false);
    }

    /// @notice Tests that non-owners cannot allow implementations
    function testAllowImplementationShouldRevertIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        factory.allowImplementation(address(1), true);
    }

    /// @notice Tests that non-owners cannot allow calls
    function testAllowCallShouldRevertIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        factory.allowCall(address(1), 0x01020304, true);
    }

    /// @notice Tests that the factory owner can successfully allow and disallow implementations
    /// @param a1 The first address to test implementation allowance
    /// @param a2 The second address to test implementation allowance
    function testAllowImplementationAsOwnerShouldWork(
        address a1,
        address a2
    ) public {
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

    /// @notice Tests that the factory owner can successfully allow and disallow calls
    /// @param a1 The first address to test call allowance
    /// @param s1 The first function selector to test call allowance
    /// @param a2 The second address to test call allowance
    /// @param s2 The second function selector to test call allowance
    function testAllowCallAsOwnerShouldWork(
        address a1,
        bytes4 s1,
        address a2,
        bytes4 s2
    ) public {
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

    /// @notice Tests that creating an account without a valid implementation should revert
    /// @param a The address to test as a potential invalid implementation
    function testCreateAccountWithoutImplementation(address a) public {
        vm.expectRevert("AccountFactory: invalid implementation");
        factory.createAccount(a);
    }

    /// @notice Tests successful account creation with a valid implementation
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
