// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Loan.sol";
import "lib/solmate/src/tokens/ERC20.sol";

contract testERC20 is ERC20 {

    constructor(string memory name, string memory symbol, uint8 decimals, address user1, address user2, uint256 mintAmount) ERC20(name, symbol, decimals) {
        _mint(user1, mintAmount);
        _mint(user2, mintAmount);
        totalSupply += (mintAmount * 2);
    }
}

contract LoanTest is Test {

    TermFactory public myTermFactory;
    LendingTerm public myLoan;
    ERC20 public myLendToken;
    ERC20 public myCollateralToken;

    address myLender = vm.addr(1);
    address myBorrower = vm.addr(2);
//function deal(address token, address to, uint256 give, bool adjust) external;

    function setUp() public {
        myTermFactory = new TermFactory();
        myLendToken = new testERC20("DAI Stablecoin", "DAI", 18, myLender, myBorrower, 100000000000000000000000);
        myCollateralToken = new testERC20("Wrapped Ether", "WETH", 18, myLender, myBorrower, 100000000000000000000000);
        myLoan = LendingTerm(myTermFactory.defineTerms(address(myLendToken), address(myCollateralToken), 98, 4, 50, 100));
    }

    // test that a new loan term can be defined and that the borrow token is encoded correctly
    function testDefineTerms() public {
        assertEq(myLoan.borrowToken(), address(myLendToken));
    }
//    function borrowTokens(uint256 terms, address lender, uint256 collateralAmount, uint256 borrowAmount) public {

    function testBorrowTokens() public {
        vm.startPrank(myLender);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        vm.stopPrank();
        vm.startPrank(myBorrower);
        myCollateralToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.borrowTokens(myLender, 100000000000000000000000, 100000000000000000000000);
        vm.stopPrank();
        assertEq(myLendToken.balanceOf(myBorrower), 200000000000000000000000, "Borrow token balance is not correct.");
        assertEq(myCollateralToken.balanceOf(myBorrower), 0, "Collateral token balance is not correct.");
    }

    function testCallLoan() public {
        vm.startPrank(myLender);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        vm.stopPrank();
        vm.startPrank(myBorrower);
        myCollateralToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.borrowTokens(myLender, 10000000000000000000000, 10000000000000000000000);
        vm.stopPrank();
        vm.startPrank(myLender);
        uint256 myBlock = block.number;
        uint256 expectedBalance = 10000000000000000000000 - (10000000000000000000000 / 50);
        myLoan.callPosition(0);
        vm.stopPrank();
        assertEq(myLoan.getCallBlock(0), myBlock);
        assertEq(myLoan.getDebtBalance(0), expectedBalance);
    }

    function testRepayBorrow() public {
        uint256 myExpectedBalance = 100000000000000000000000 - 400000000000000000;
        uint256 myExpectedReturn = 100000000000000000000000 + 400000000000000000;
        vm.startPrank(myLender);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        vm.stopPrank();
        vm.startPrank(myBorrower);
        myCollateralToken.approve(address(myLoan), 100000000000000000000000);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.borrowTokens(myLender, 10000000000000000000000, 10000000000000000000);
        vm.warp(block.timestamp + 31536000);
        myLoan.repayBorrow(0);
        assertEq(myLendToken.balanceOf(myBorrower), myExpectedBalance, "The borrower's balance is incorrect.");
        assertEq(myLendToken.balanceOf(address(myLender)), myExpectedReturn, "The borrower did not repay the expected amount.");
    }

    // if the loan has been called, the borrower's debt should be lower
    function testCallAndRepay() public {
        uint256 myExpectedBalance = 100000000000000000000000 + (10000000000000000000 / 50);

        vm.startPrank(myLender);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        vm.stopPrank();
        vm.startPrank(myBorrower);
        myCollateralToken.approve(address(myLoan), 100000000000000000000000);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.borrowTokens(myLender, 10000000000000000000000, 10000000000000000000);
        vm.stopPrank();
        vm.startPrank(myLender);
        myLoan.callPosition(0);
        vm.stopPrank();
        vm.startPrank(myBorrower);
        myLoan.repayBorrow(0);
        vm.stopPrank();
        assertEq(myLendToken.balanceOf(myBorrower), myExpectedBalance, "The borrower's balance is incorrect.");
    }
}
