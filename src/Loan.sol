// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Loan {

    struct LendingTerm {
        uint256 denomination; // the borrowed token and denomination for interest & call fee
        uint256 collateralRatio; // the borrow limit, expressed in terms of the number of borrow tokens per collateral tokens
        // this ratio is also used as the liquidation threshold
        uint256 interestRate; // the interest rate per block
        uint256 callFee; // the fee users must pay to call the loan
    }

    // per account per lending token, how much is available to borrow
    mapping(address => mapping(address => uint256)) public userAvailableBalance;

    // per account per collateral token, the lending terms they are willing to offer
    mapping(address => mapping(address => LendingTerm)) public availableTerms;

    // this function just deposits a certain amount of a given lending token
    // defining lending terms happens separately
    function lendTokens(address token, uint256 amount) public {
        ERC20(token).transferFrom(msg.sender, address(this), amount);
        userAvailableBalance[msg.sender] += amount;
    }

    function withdrawTokens(address token, uint256 amount) public {
        ERC20(token).transfer(msg.sender, amount);
        require(userAvailableBalance[msg.sender] >=0);
    }

    uint256 public number;

    function setNumber(uint256 newNumber) public {
        number = newNumber;
    }

    function increment() public {
        number++;
    }
}
