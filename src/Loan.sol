// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "lib/solmate/src/tokens/ERC20.sol";

contract Loan {

    struct LendingTerm {
        address borrowToken; // the borrowed token and denomination for interest & call fee
        address collateralToken; // the token accepted as collateral
        uint256 collateralRatio; // the borrow limit, expressed in terms of the number of borrow tokens per collateral token
        // this ratio is also used as the liquidation threshold
        uint256 interestRate; // the interest rate in terms of the borrow token, bips annual
        uint256 callFee; // the fee users must pay to call the loan in terms of the borrow token, bips
    }

    struct DebtPosition {
        address lender;
        address borrower;
        uint256 debtBalance;
        uint256 terms;
        uint256 originationTime;
        bool isCalled;
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
    // interest in terms of bips annual
    // call fee in terms of bips
    function defineTerms(address borrowToken, address collateralToken, uint256 collateralRatio, uint256 interestRate, uint256 callFee) public {
        availableTerms.push(
            LendingTerm(
                {
                    borrowToken: borrowToken,
                    collateralToken: collateralToken,
                    collateralRatio: collateralRatio,
                    interestRate: interestRate,
                    callFee: callFee
                }
            )
        );
    }

    // inputs:
    // array index of the desired terms
    // the lender to borrow from
    // the amount of collateral to deposit
    // how many tokens to borrow
    function borrowTokens(uint256 terms, address lender, uint256 collateralAmount, uint256 borrowAmount) public {
        // TODO safemath, require that the proposed loan meets the loan terms
        require(availableTerms[terms].collateralRatio * collateralAmount <= borrowAmount);
        // require that the lender has approved these terms
        require(lenderTerms[lender][terms]);

        // record the new debt position
        debtPositions.push(
            DebtPosition(
                {
                    lender: lender,
                    borrower: msg.sender,
                    debtBalance: borrowAmount,
                    terms: terms,
                    originationTime: block.timestamp,
                    isCalled: false
                }
            )
        );

        // pull collateral tokens from the borrower
        ERC20(availableTerms[terms].collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        // pull debt tokens from lender and send to the borrower
        ERC20(availableTerms[terms].borrowToken).transferFrom(lender, msg.sender, borrowAmount);
    }

    function getBorrowToken(uint256 id) external view returns (address) {
        return availableTerms[id].borrowToken;
    }
}
