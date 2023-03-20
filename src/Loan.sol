// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "lib/solmate/src/tokens/ERC20.sol";

contract Loan {

    struct LendingTerm {
        address borrowToken; // the borrowed token and denomination for interest & call fee
        address collateralToken; // the token accepted as collateral
        uint256 collateralRatio; // the borrow limit, expressed in terms of the number of borrow tokens per collateral token
        // this ratio is also used as the liquidation threshold
        // TODO: safemath so this can handle collateral tokens with small unit value
        uint256 interestRate; // the interest rate in terms of percent annual
        uint256 callFee; // the fee users must pay to call the loan
        // expressed in terms of the divisor to apply to the total debt
        // 20 would imply a 5% call fee, 50 would imply a 2% call fee, and so on
        uint256 callPeriod; // the time in blocks that the borrower has to repay the loan before the collateral is seized by the lender
    }

    struct DebtPosition {
        address lender;
        address borrower;
        uint256 debtBalance;
        uint256 underlyingBalance;
        uint256 terms;
        uint256 originationTime;
        uint256 callBlock;
    }

    LendingTerm[] public availableTerms;
    DebtPosition[] public debtPositions;

    // keep track of which terms lenders have agreed to
    mapping(address => mapping(uint256 => bool)) public lenderTerms;

    // anyone can define a new LendingTerm if they pay the gas cost
    // inputs:
    // the token to lend/borrow
    // the token to use as collateral
    // the number of borrowable tokens per collateral token
    // TODO: safemath so this can handle collateral tokens with small unit value
    // interest in terms of bips annual
    // call fee in terms of bips
    // call period in blocks
    function defineTerms(
        address borrowToken,
        address collateralToken,
        uint256 collateralRatio,
        uint256 interestRate,
        uint256 callFee,
        uint256 callPeriod)
        public {
            availableTerms.push(
                LendingTerm(
                    {
                        borrowToken: borrowToken,
                        collateralToken: collateralToken,
                        collateralRatio: collateralRatio,
                        interestRate: interestRate,
                        callFee: callFee,
                        callPeriod: callPeriod
                    }
                )
            );
    }

    function approveTerms(uint256 terms) public {
        lenderTerms[msg.sender][terms] = true;
    }

    // inputs:
    // array index of the desired terms
    // the lender to borrow from
    // the amount of collateral to deposit
    // how many tokens to borrow
    function borrowTokens(uint256 terms, address lender, uint256 collateralAmount, uint256 borrowAmount) public {
        // TODO safemath, require that the proposed loan meets the loan terms
        require(availableTerms[terms].collateralRatio * collateralAmount >= borrowAmount, "You can't borrow that much.");
        // require that the lender has approved these terms
        require(lenderTerms[lender][terms], "The lender has not agreed to these terms.");

        // record the new debt position
        debtPositions.push(
            DebtPosition(
                {
                    lender: lender,
                    borrower: msg.sender,
                    debtBalance: borrowAmount,
                    underlyingBalance: 0,
                    terms: terms,
                    originationTime: block.timestamp,
                    callBlock: 0 // a call block of zero indicates that the loan has not been called
                }
            )
        );

        // pull collateral tokens from the borrower
        ERC20(availableTerms[terms].collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        // pull debt tokens from lender and send to the borrower
        ERC20(availableTerms[terms].borrowToken).transferFrom(lender, msg.sender, borrowAmount);
    }

    function callPosition(uint256 index) public {
        // pull the call fee from the caller, denominated in the borrow token
        ERC20(availableTerms[debtPositions[index].terms].borrowToken).transferFrom(
            msg.sender,
            address(this),
            debtPositions[index].debtBalance / availableTerms[debtPositions[index].terms].callFee
        );
        require(debtPositions[index].callBlock == 0); // require that the loan has not already been called
        require(debtPositions[index].debtBalance > 0); // require there is a nonzero debt balance
        debtPositions[index].callBlock = block.number; // set the call block to the current block
        debtPositions[index].debtBalance -= debtPositions[index].debtBalance / availableTerms[debtPositions[index].terms].callFee; // deduct the call fee from the borrower's debt
    }

    // anyone can repay a debt on behalf of the borrower
    // for now and for simplicity, full repayment only
    function repayBorrow(uint256 index) public {

        // first, compute the interest owed
        // the interest rate is expressed in terms of borrow tokens per year per token borrowed
        uint256 amountToPay = 
            debtPositions[index].debtBalance +
            (
                debtPositions[index].debtBalance * // the amount borrowed
                availableTerms[debtPositions[index].terms].interestRate * // times the annual rate
                (block.timestamp - debtPositions[index].originationTime) / 3153600000 // get the amount of time elapsed since borrow and convert to years
            );

        ERC20(availableTerms[debtPositions[index].terms].borrowToken).transferFrom(
            msg.sender,
            address(this),
            amountToPay);
        debtPositions[index].underlyingBalance += amountToPay;
        debtPositions[index].debtBalance = 0;
        debtPositions[index].callBlock = 0; // the loan can no longer be called or collateral seized once the debt is repaid
    }

    function getDebtBalance(uint256 id) external view returns (uint256) {
        return(
            debtPositions[id].debtBalance +
            (
                debtPositions[id].debtBalance * // the amount borrowed
                availableTerms[debtPositions[id].terms].interestRate * // times the annual rate
                (block.timestamp - debtPositions[id].originationTime) / 3153600000 // get the amount of time elapsed since borrow and convert to years
            )
        );
    }

    function getCallBlock(uint256 id) external view returns (uint256) {
        return debtPositions[id].callBlock;
    }

    function getBorrowToken(uint256 id) external view returns (address) {
        return availableTerms[id].borrowToken;
    }
}
