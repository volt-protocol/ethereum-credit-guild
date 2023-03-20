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
    Loan public myLoan;
    ERC20 public myLendToken;
    ERC20 public myCollateralToken;

    address myLender = vm.addr(1);
    address myBorrower = vm.addr(2);
//function deal(address token, address to, uint256 give, bool adjust) external;

    function setUp() public {
        myLoan = new Loan();
        myLendToken = new testERC20("DAI Stablecoin", "DAI", 18, myLender, myBorrower, 100000000000000000000000);
        myCollateralToken = new testERC20("Wrapped Ether", "WETH", 18, myLender, myBorrower, 100000000000000000000000);
        myLoan.defineTerms(address(myLendToken), address(myCollateralToken), 98, 4, 50, 100);
    }

    // test that a new loan term can be defined and that the borrow token is encoded correctly
    function testDefineTerms() public {
        assertEq(myLoan.getBorrowToken(0), address(myLendToken));
    }
//    function borrowTokens(uint256 terms, address lender, uint256 collateralAmount, uint256 borrowAmount) public {

    function testBorrowTokens() public {
        vm.startPrank(myLender);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.approveTerms(0);
        vm.stopPrank();
        vm.startPrank(myBorrower);
        myCollateralToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.borrowTokens(0, myLender, 100000000000000000000000, 100000000000000000000000);
        vm.stopPrank();
        assertEq(myLendToken.balanceOf(myBorrower), 200000000000000000000000, "Borrow token balance is not correct.");
        assertEq(myCollateralToken.balanceOf(myBorrower), 0, "Collateral token balance is not correct.");
    }

    function testCallLoan() public {
        vm.startPrank(myLender);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.approveTerms(0);
        vm.stopPrank();
        vm.startPrank(myBorrower);
        myCollateralToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.borrowTokens(0, myLender, 10000000000000000000000, 10000000000000000000000);
        vm.stopPrank();
        vm.startPrank(myLender);
        uint256 myBlock = block.number;
        myLoan.callPosition(0);
        vm.stopPrank();
        assertEq(myLoan.getCallBlock(0), myBlock);
    }

    function testRepayBorrow() public {
        uint256 myExpectedBalance = 100000000000000000000000 - 400000000000000000;
        vm.startPrank(myLender);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.approveTerms(0);
        vm.stopPrank();
        vm.startPrank(myBorrower);
        myCollateralToken.approve(address(myLoan), 100000000000000000000000);
        myLendToken.approve(address(myLoan), 100000000000000000000000);
        myLoan.borrowTokens(0, myLender, 10000000000000000000000, 10000000000000000000);
        vm.warp(block.timestamp + 31536000);
        myLoan.repayBorrow(0);
        console.log(myLendToken.balanceOf(myBorrower));
        assertEq(myLendToken.balanceOf(myBorrower), myExpectedBalance);
    }
}
