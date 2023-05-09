// SPX license identifier: MIT

pragma solidity ^0.8.13;

import "@forge-std/Test.sol";
import "./Credit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract myCollateralToken is ERC20 {
    constructor(address borrower, uint256 amount) ERC20("MyCollateralToken", "MCT", 18) {
        _mint(borrower, amount);
    }
}

contract CreditTest is Test {

    Core core;
    Credit credit;
    address governor;
    Guild guild;

    function setUp() public {
        governor = address(0x1);

        core = new Core(governor, 1000, 100);

        credit = Credit(core.credit());
        guild = Guild(core.guild());

    }

//     // test define lending term
    function testDefineLendingTerm() public {
        address collateralToken = address(new myCollateralToken(address(this), 1000));
        uint256 collateralRatio = 2;
        uint256 interestRate = 2e16;
        uint256 callFee = 20;
        uint256 callPeriod = 100;
        address lendingTerm = address(credit.defineLendingTerm(collateralToken, collateralRatio, interestRate, callFee, callPeriod));
        assertEq(CreditLendingTerm(lendingTerm).collateralToken(), collateralToken);
        assertEq(CreditLendingTerm(lendingTerm).collateralRatio(), collateralRatio);
        assertEq(CreditLendingTerm(lendingTerm).interestRate(), interestRate);
        assertEq(CreditLendingTerm(lendingTerm).callFee(), callFee);
        assertEq(CreditLendingTerm(lendingTerm).callPeriod(), callPeriod);
    }

    // test borrowing tokens
    function testBorrowTokens() public {
        address borrower = address(0x2);
        address collateralToken = address(new myCollateralToken(borrower, 1000));
        uint256 collateralRatio = 2;
        uint256 interestRate = 10;
        uint256 callFee = 20;
        uint256 callPeriod = 100;
        address lendingTerm = address(credit.defineLendingTerm(collateralToken, collateralRatio, interestRate, callFee, callPeriod));
        uint256 collateralAmount = 100;
        uint256 borrowAmount = 200;

        vm.startPrank(governor);
        credit.approveLendingTerm(lendingTerm);
        CreditLendingTerm(lendingTerm).setAvailableCredit(borrowAmount);
        vm.stopPrank();

        vm.startPrank(borrower);
        myCollateralToken(collateralToken).approve(lendingTerm, collateralAmount);
        CreditLendingTerm(lendingTerm).borrowTokens(collateralAmount);
        vm.stopPrank();

        assertEq(credit.balanceOf(borrower), borrowAmount);
        assertEq(CreditLendingTerm(lendingTerm).getDebtBalance(0), borrowAmount);
        assertEq(CreditLendingTerm(lendingTerm).getCollateralBalance(0), collateralAmount);

    }

    function testRepayTokens() public {
        address borrower = address(0x2);
        address collateralToken = address(new myCollateralToken(borrower, 1000));
        uint256 collateralRatio = 2;
        uint256 interestRate = 10;
        uint256 callFee = 20;
        uint256 callPeriod = 100;
        address lendingTerm = address(credit.defineLendingTerm(collateralToken, collateralRatio, interestRate, callFee, callPeriod));
        uint256 collateralAmount = 100;
        uint256 borrowAmount = 200;


        vm.startPrank(governor);
        credit.approveLendingTerm(lendingTerm);
        CreditLendingTerm(lendingTerm).setAvailableCredit(borrowAmount);
        // mint an extra 100 tokens to the borrower so they can repay their loan
        credit.mintForGovernor(borrower, 100);
        vm.stopPrank();

        vm.startPrank(borrower);
        myCollateralToken(collateralToken).approve(lendingTerm, collateralAmount);
        CreditLendingTerm(lendingTerm).borrowTokens(collateralAmount);
        vm.stopPrank();

        // warp to 10 minutes later and repay the loan
        vm.warp(block.timestamp + 10 minutes);
        vm.startPrank(borrower);
        credit.approve(lendingTerm, borrowAmount);
        CreditLendingTerm(lendingTerm).closePosition(0);
        vm.stopPrank();

        assertEq(ERC20(collateralToken).balanceOf(lendingTerm), 0);

        // calculate the interest due based on the borrow amount, the interest rate, the number of blocks, and an average block time of 12 seconds
        uint256 interest = borrowAmount * interestRate * 10 / 100 / 365 / 24 / 60 / 60 / 12 * 10;

        // check that the borrower's credit balance is equal to 100 minus the interest
        assertEq(credit.balanceOf(borrower), 100 - interest);
    }

    // test calling a loan
    function testcallPosition() public {
        // create a borrower and a collateral token
        address borrower = address(0x2);
        address collateralToken = address(new myCollateralToken(borrower, 1000));
        // create a new lending term
        uint256 collateralRatio = 2;
        uint256 interestRate = 10;
        uint256 callFee = 20;
        uint256 callPeriod = 100;
        address lendingTerm = address(credit.defineLendingTerm(collateralToken, collateralRatio, interestRate, callFee, callPeriod));
        // as the governor, approve the lending term and set its credit limit to 10000
        vm.startPrank(governor);
        credit.approveLendingTerm(lendingTerm);
        CreditLendingTerm(lendingTerm).setAvailableCredit(10000);
        vm.stopPrank();
        // as the borrower, borrow 100 tokens
        vm.startPrank(borrower);
        myCollateralToken(collateralToken).approve(lendingTerm, 100);
        CreditLendingTerm(lendingTerm).borrowTokens(100);
        vm.stopPrank();
        // create a caller address and give them 100 credit tokens
        address caller = address(0x3);
        vm.startPrank(governor);
        credit.mintForGovernor(caller, 100);
        vm.stopPrank();
        // warp to 10 minutes later and call the loan
        vm.warp(block.timestamp + 10 minutes);
        vm.startPrank(caller);
        credit.approve(lendingTerm, 100);
        CreditLendingTerm(lendingTerm).callPosition(0);
        vm.stopPrank();
        // check that the caller's credit balance is 100 minus the call fee of 5% of the 200 credits borrowed
        // calculate the fee paid based on the call fee and the borrow amount
        assertEq(credit.balanceOf(caller), 90);
    }

    // test starting a liquidation after calling a loan
    function testStartLiquidation() public {
        // create a borrower and a collateral token
        address borrower = address(0x2);
        address collateralToken = address(new myCollateralToken(borrower, 1000));
        // create a new lending term
        uint256 collateralRatio = 2;
        uint256 interestRate = 10;
        uint256 callFee = 20;
        uint256 callPeriod = 100;
        address lendingTerm = address(credit.defineLendingTerm(collateralToken, collateralRatio, interestRate, callFee, callPeriod));
        // as the governor, approve the lending term and set its credit limit to 10000
        vm.startPrank(governor);
        credit.approveLendingTerm(lendingTerm);
        CreditLendingTerm(lendingTerm).setAvailableCredit(10000);
        vm.stopPrank();
        // as the borrower, borrow 100 tokens
        vm.startPrank(borrower);
        myCollateralToken(collateralToken).approve(lendingTerm, 100);
        CreditLendingTerm(lendingTerm).borrowTokens(100);
        vm.stopPrank();
        // create a caller address and give them 100 credit tokens
        address caller = address(0x3);
        vm.startPrank(governor);
        credit.mintForGovernor(caller, 100);
        vm.stopPrank();
        // warp to 1 month later and call the loan
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(caller);
        credit.approve(lendingTerm, 100);
        CreditLendingTerm(lendingTerm).callPosition(0);
        vm.stopPrank();
        // warp to 10 minutes later and start a liquidation
        vm.warp(block.timestamp + 10 minutes);
        vm.startPrank(caller);
        CreditLendingTerm(lendingTerm).startLiquidation(0);
        vm.stopPrank();
        // check that the liquidation has started
        assertEq(CreditLendingTerm(lendingTerm).getLiquidationStatus(0), true);
        // check that the debt balance was decreased by the call fee and then increased by the interest
        assertEq(CreditLendingTerm(lendingTerm).getDebtBalance(0), 191);
    }

    function testBid() public {
                // create a borrower and a collateral token
        address borrower = address(0x2);
        address collateralToken = address(new myCollateralToken(borrower, 1000));
        // create a new lending term
        uint256 collateralRatio = 2;
        uint256 interestRate = 10;
        uint256 callFee = 20;
        uint256 callPeriod = 100;
        address lendingTerm = address(credit.defineLendingTerm(collateralToken, collateralRatio, interestRate, callFee, callPeriod));
        // as the governor, approve the lending term and set its credit limit to 10000
        vm.startPrank(governor);
        credit.approveLendingTerm(lendingTerm);
        CreditLendingTerm(lendingTerm).setAvailableCredit(10000);
        vm.stopPrank();
        // as the borrower, borrow 100 tokens
        vm.startPrank(borrower);
        myCollateralToken(collateralToken).approve(lendingTerm, 100);
        CreditLendingTerm(lendingTerm).borrowTokens(100);
        vm.stopPrank();
        // create a caller address and give them 100 credit tokens
        address caller = address(0x3);
        vm.startPrank(governor);
        credit.mintForGovernor(caller, 100);
        vm.stopPrank();
        // warp to 1 month later and call the loan
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(caller);
        credit.approve(lendingTerm, 100);
        CreditLendingTerm(lendingTerm).callPosition(0);
        vm.stopPrank();
        // warp to 500 seconds later and start a liquidation
        vm.warp(block.timestamp + 500);
        vm.startPrank(caller);
        CreditLendingTerm(lendingTerm).startLiquidation(0);
        vm.stopPrank();
       
        // create a bidder address and give them 1000 credit tokens
        address bidder = address(0x4);
        vm.startPrank(governor);
        credit.mintForGovernor(bidder, 1000);
        vm.stopPrank();

        // store the current debt balance
        uint256 debtBalance = CreditLendingTerm(lendingTerm).getDebtBalance(0);
        
        // bid in the auction
        vm.startPrank(bidder);
        credit.approve(Core(core).auctionHouse(), 300);
        AuctionHouse(Core(core).auctionHouse()).bid(lendingTerm, 0);
        vm.stopPrank();

        // check that the bidder received 50 collateral tokens
        assertEq(myCollateralToken(collateralToken).balanceOf(bidder), 50);
        // check that the bidder's credit balance decreased by the debt balance
        assertEq(credit.balanceOf(bidder), 1000 - debtBalance);
        // check that the borrower's collateral balance increased by 50
        assertEq(myCollateralToken(collateralToken).balanceOf(borrower), 950);
    }
}