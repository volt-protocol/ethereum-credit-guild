// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Loan.sol";

contract LoanTest is Test {
    Loan public loan;

    function setUp() public {
        loan = new Loan();
        loan.setNumber(0);
    }

    function testIncrement() public {
        loan.increment();
        assertEq(loan.number(), 1);
    }

    function testSetNumber(uint256 x) public {
        loan.setNumber(x);
        assertEq(loan.number(), x);
    }
}
