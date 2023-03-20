// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Loan.sol";
import "lib/solmate/src/tokens/ERC20.sol";

contract testERC20A is ERC20("Circle Dollar", "USDC", 8) {}
contract testERC20B is ERC20("Hexagon Bond Token", "HBT", 18) {}

contract LoanTest is Test {
    Loan public loan;
    testERC20A public myLendToken;
    testERC20B public myCollateralToken;


    function setUp() public {
        loan = new Loan();
        myLendToken = new testERC20A();
        myCollateralToken = new testERC20B();
    }

    // test that a new loan term can be defined and that the borrow token is encoded correctly
    function testDefineTerms() public {
        loan.defineTerms(address(myLendToken), address(myCollateralToken), 1000000000, 450, 50);
        assertEq(loan.getBorrowToken(0), address(myLendToken));
    }
}
