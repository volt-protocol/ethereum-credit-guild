// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Loan.sol";
import "lib/solmate/src/tokens/ERC20.sol";

contract testERC20 is ERC20 {

    constructor(string memory name, string memory symbol, uint8 decimals, address user, uint256 mintAmount) ERC20(name, symbol, decimals) {
        _mint(user, mintAmount);
        totalSupply += mintAmount;
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
        myLendToken = new testERC20("DAI Stablecoin", "DAI", 18, myLender, 100000000000000000000000);
        myCollateralToken = new testERC20("Wrapped Ether", "WETH", 18, myBorrower, 100000000000000000000000);
        myLoan.defineTerms(address(myLendToken), address(myCollateralToken), 98, 425, 50);
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
        vm.stopPrank;
        assertEq(myLendToken.balanceOf(myBorrower), 100000000000000000000000);
    }
}
