// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ClearingHouse {
    
    // the clearinghouse is a factory for issuing and settling loans
    // users construct signed messages offchain specifying the terms under which they wish to lend or borrower
    // anyone can call in with a matched set of terms to construct a loan
    // the clearinghouse stores collateral tokens until a loan is repaid or liquidated

    struct Loan {
        address borrower;
        address lender;
        address borrowToken;
        address collateralToken;
        uint256 borrowAmount;
        uint256 collateralAmount;
        uint256 interestRate; // expressed as a divisor to apply to the total debt per year
        // this structure cannot support debt amounts that are too small, tokens with weirdly low decimals will need to be wrapped or handled differently
        uint256 callFee; // the cost paid by the loan caller (most likely the lender) to the borrower
        uint256 callPeriod; // the period of time until the collateral can be seized
        uint256 callTime; // a call time of 0 indicates that the loan has not been called
        uint256 originationTime; // the time the loan was initiated
    }

    Loan[] public loans;

    // to initiate a loan, pass in the terms desired and a signature from both borrower and lender
    function newLoan(
        address borrower,
        address lender,
        address borrowToken,
        address collateralToken,
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint256 interestRate,
        uint256 callFee,
        uint256 callPeriod,
        bytes calldata borrowerSignedMessage,
        bytes calldata lenderSignedMessage
    ) public {
        // encode the loan terms
        bytes32 loanTerms = keccak256(abi.encode(borrower, lender, borrowToken, collateralToken, borrowAmount, collateralAmount, interestRate, callFee, callPeriod));
        
        // use ecrecover to check that the borrower signed the loan terms
        require(ecrecover(loanTerms, 27, bytes32(borrowerSignedMessage[0:32]), bytes32(borrowerSignedMessage[32:64])) == borrower, "borrower signature invalid");

        // use ecrecover to check that the lender signed the loan terms
        require(ecrecover(loanTerms, 27, bytes32(lenderSignedMessage[0:32]), bytes32(lenderSignedMessage[32:64])) == lender, "lender signature invalid");

        // pull the collateral from the borrower
        ERC20(collateralToken).transferFrom(borrower, address(this), collateralAmount);

        // pull the borrow token from the lender and send it to the borrower
        ERC20(borrowToken).transferFrom(lender, borrower, borrowAmount);
        
        // create loan
        loans.push(Loan(borrower, lender, borrowToken, collateralToken, borrowAmount, collateralAmount, interestRate, callFee, callPeriod, 0, block.timestamp));
    }

    // to repay a loan, pass in the loan id
    // calculate the total debt including the interest
    // pull the right amount of tokens from the borrower and send them to the lender
    // return the collateral to the borrower
    // delete the loan
    function repayLoan(uint256 loanId) public {
        Loan storage loan = loans[loanId];
        // the interest is equal to the debt divided by the interestRate multipled by the time since origination
        uint256 interest = loan.borrowAmount / loan.interestRate * (block.timestamp - loan.originationTime);
        // pull the total debt from the caller
        ERC20(loan.borrowToken).transferFrom(msg.sender, loan.lender, loan.borrowAmount + interest);
        // return the collateral to the borrower
        ERC20(loan.collateralToken).transfer(loan.borrower, loan.collateralAmount);
        // delete the loan
        delete loans[loanId];
    }

    function callLoan(uint256 loanId) public {
        Loan storage loan = loans[loanId];
        // calculate the fee by dividing the debt by the callFee
        uint256 myFee = loan.borrowAmount / loan.callFee;
        // pull the fee from caller and send it to the borrower
        ERC20(loan.borrowToken).transferFrom(msg.sender, loan.borrower, myFee);
        // set the call time
        loan.callTime = block.timestamp;
    }

    function seizeCollateral(uint256 loanId) public {
        Loan storage loan = loans[loanId];
        // check that the loan has been called
        require(loan.callTime > 0, "loan has not been called");
        // check that the call period has elapsed
        require(block.timestamp - loan.callTime > loan.callPeriod, "call period has not elapsed");
        // pull the collateral from the borrower and send it to the lender
        ERC20(loan.collateralToken).transferFrom(loan.borrower, loan.lender, loan.collateralAmount);
        // delete the loan
        delete loans[loanId];
    }
}
