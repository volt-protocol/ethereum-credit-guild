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

    ClearingHouse public myClearingHouse;
    ERC20 public myLendToken;
    ERC20 public myCollateralToken;

    address myLender = vm.addr(1);
    address myBorrower = vm.addr(2);

    function setUp() public {
        myClearingHouse = new ClearingHouse();
        myLendToken = new testERC20("DAI Stablecoin", "DAI", 18, myLender, myBorrower, 100000000000000000000000);
        myCollateralToken = new testERC20("Wrapped Ether", "WETH", 18, myLender, myBorrower, 100000000000000000000000);
    }

    // sign a message as the lender and borrower for the following loan terms, using correct decimals for the tokens:
    // borrow token DAI
    // collateral token WETH
    // borrow amount 100 DAI
    // collateral amount 1 WETH
    // interest rate 20
    // call fee 50
    // call period 1 hour
    function testNewLoan() public {
        // encode the loan parameters
        bytes memory loanParams = abi.encode(address(myLendToken), address(myCollateralToken), 100000000000000000000, 1000000000000000000, 20, 50, 3600);
        // sign the loan parameters as the lender
        bytes memory lenderSignature = vm.sign(loanParams, myLender);
        // sign the loan parameters as the borrower
        bytes memory borrowerSignature = vm.sign(loanParams, myBorrower);
        // call newLoan with the loan parameters and signatures
        myClearingHouse.newLoan(address(myLendToken), address(myCollateralToken), 100000000000000000000, 1000000000000000000, 20, 50, 3600, borrowerSignature, lenderSignature);
        // check that the borrower's balance is 100 DAI more than initially
        assertEq(myLendToken.balanceOf(myBorrower), 100000000000000000000000 + 100000000000000000000);
        // check that the clearinghouse has received 1 WETH
        assertEq(myCollateralToken.balanceOf(address(myClearingHouse)), 1000000000000000000);
    }
}
