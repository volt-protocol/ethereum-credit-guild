// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "lib/solmate/src/tokens/ERC20.sol";

/*

Each "LendingTerm" is like a Liquity instance: a pair of assets,
one used as collateral, the other available to borrow, a leverage ratio,
an interest rate, a "call fee" giving lenders a claim on borrower collateral,
a call period defining how long a borrower has to repay before collateral is seized,
and possibly other parameters such as those governing a liquidation auction.

To use a given LendingTerm, a lender should approve the term contract address on borrowToken
with the amount they wish to lend.

*/

contract LendingTerm {
    address public borrowToken;
    address public collateralToken;
    // in terms of the number of borrow tokens per collateral token
    uint256 public collateralRatio;
    // in terms of percent annual
    uint256 public interestRate;
    // in terms of the divisor to apply to the total debt
    // 20 implies a 5% fee, 50 a 2% fee, and so on
    uint256 public callFee;
    uint256 public callPeriod;

    constructor(address _borrowToken, address _collateralToken, uint256 _collateralRatio, uint256 _interestRate, uint256 _callFee, uint256 _callPeriod) {
        borrowToken = _borrowToken;
        collateralToken = _collateralToken;
        collateralRatio = _collateralRatio;
        interestRate = _interestRate;
        callFee = _callFee;
        callPeriod = _callPeriod;
    }

    struct DebtPosition {
        address lender;
        address borrower;
        uint256 debtBalance;
        uint256 collateralBalance;
        uint256 originationTime;
        uint256 callBlock;
    }

    DebtPosition[] public debtPositions;    

    // inputs:
    // array index of the desired terms
    // the lender to borrow from
    // the amount of collateral to deposit
    // how many tokens to borrow
    function borrowTokens(address lender, uint256 collateralAmount, uint256 borrowAmount) public {
        // TODO safemath, require that the proposed loan meets the loan terms
        require(collateralRatio * collateralAmount >= borrowAmount, "You can't borrow that much.");

        // record the new debt position
        debtPositions.push(
            DebtPosition(
                {
                    lender: lender,
                    borrower: msg.sender,
                    debtBalance: borrowAmount,
                    collateralBalance: collateralAmount,
                    originationTime: block.timestamp,
                    callBlock: 0 // a call block of zero indicates that the loan has not been called
                }
            )
        );

        // pull collateral tokens from the borrower
        ERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        // pull debt tokens from lender and send to the borrower
        ERC20(borrowToken).transferFrom(lender, msg.sender, borrowAmount);
    }

        function callPosition(uint256 index) public {
        // pull the call fee from the caller, denominated in the borrow token
        ERC20(borrowToken).transferFrom(
            msg.sender,
            address(this),
            debtPositions[index].debtBalance / callFee
        );
        require(debtPositions[index].callBlock == 0); // require that the loan has not already been called
        require(debtPositions[index].debtBalance > 0); // require there is a nonzero debt balance
        debtPositions[index].callBlock = block.number; // set the call block to the current block
        debtPositions[index].debtBalance -= (debtPositions[index].debtBalance / callFee); // deduct the call fee from the borrower's debt
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
                interestRate * // times the annual rate
                (block.timestamp - debtPositions[index].originationTime) / 3153600000 // get the amount of time elapsed since borrow and convert to years
            );

        // repay the lender
        ERC20(borrowToken).transferFrom(
            msg.sender,
            debtPositions[index].lender,
            amountToPay
        );

        // release the borrower's collateral
        uint256 amountToRelease = debtPositions[index].collateralBalance;
        debtPositions[index].collateralBalance = 0;
        ERC20(collateralToken).transfer(
            msg.sender,
            amountToRelease
        );

        debtPositions[index].debtBalance = 0;
        debtPositions[index].callBlock = 0; // the loan can no longer be called or collateral seized once the debt is repaid
    }

    function getDebtBalanceCurrent(uint256 id) external view returns (uint256) {
        return(
            debtPositions[id].debtBalance +
            (
                debtPositions[id].debtBalance * // the amount borrowed
                interestRate * // times the annual rate
                (block.timestamp - debtPositions[id].originationTime) / 3153600000 // get the amount of time elapsed since borrow and convert to years
            )
        );
    }

    function getCallBlock(uint256 id) external view returns (uint256) {
        return debtPositions[id].callBlock;
    }

    function getDebtBalance(uint256 id) external view returns (uint256) {
        return debtPositions[id].debtBalance;
    }
}

contract TermFactory {
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
        public returns (address) {
            return address(
                new LendingTerm(borrowToken, collateralToken, collateralRatio, interestRate, callFee, callPeriod)
            );
    }
}
