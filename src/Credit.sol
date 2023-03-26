// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Loan.sol";
import "lib/solmate/src/tokens/ERC20.sol";

contract CreditLendingTerm {

    address public governor;
    address public credit;
    address public collateralToken;
    uint256 public collateralRatio;
    uint256 public interestRate;
    uint256 public callFee;
    uint256 public callPeriod;

    modifier onlyGovernor() {
        require(msg.sender == governor, "Only the governor can do that.");
        _;
    }

    constructor(address _governor, address _credit, address _collateralToken, uint256 _collateralRatio, uint256 _interestRate, uint256 _callFee, uint256 _callPeriod) {
        governor = _governor;
        credit = _credit;
        collateralToken = _collateralToken;
        collateralRatio = _collateralRatio;
        interestRate = _interestRate;
        callFee = _callFee;
        callPeriod = _callPeriod;
    }

    struct DebtPosition {
        address borrower;
        uint256 debtBalance;
        uint256 collateralBalance;
        uint256 originationTime;
        uint256 callBlock;
    }

    function getBorrower(uint256 index) public view returns (address) {
        return debtPositions[index].borrower;
    }

    function getDebtBalance(uint256 index) public view returns (uint256) {
        return debtPositions[index].debtBalance;
    }

    function getCollateralBalance(uint256 index) public view returns (uint256) {
        return debtPositions[index].collateralBalance;
    }

    function getOriginationTime(uint256 index) public view returns (uint256) {
        return debtPositions[index].originationTime;
    }

    function getCallBlock(uint256 index) public view returns (uint256) {
        return debtPositions[index].callBlock;
    }

    DebtPosition[] public debtPositions;

    uint256 public availableCredit;

    function setAvailableCredit(uint256 _availableCredit) public onlyGovernor {
        availableCredit = _availableCredit;
    }

    function borrowTokens(uint256 collateralAmount, uint256 borrowAmount) public {
        require(collateralRatio * collateralAmount >= borrowAmount, "You can't borrow that much.");
        require(borrowAmount <= availableCredit, "Not enough credit available.");
        availableCredit = availableCredit - borrowAmount;
        debtPositions.push(DebtPosition(msg.sender, borrowAmount, collateralAmount, block.timestamp, block.number + callPeriod));
        ERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        Credit(credit).mintForLoan(msg.sender, borrowAmount);
    }

    // anyone can repay a loan
    // transfer the debt token to this contract and burn it
    // transfer the collateral token to the borrower
    // delete the debt position
    // increment the available credit
    function closePosition(uint256 index) public {
        // store the debt position in memory
        DebtPosition memory debtPosition = debtPositions[index];
        // delete the debt position
        delete debtPositions[index];

        // calculate the interest based on the time elapsed since origination
        uint256 interest = debtPosition.debtBalance * interestRate * (block.timestamp - debtPosition.originationTime) / 365 days / 100;

        // burn credit tokens from the caller to repay the loan plus interest
        Credit(credit).burnFrom(msg.sender, debtPosition.debtBalance + interest);

        // transfer the collateral token to the borrower
        ERC20(collateralToken).transfer(debtPosition.borrower, debtPosition.collateralBalance);

        // increment the available credit
        availableCredit = availableCredit + debtPosition.debtBalance;
    }

    function callPosition(uint256 index) public {
        // require that the loan has not yet been called
        require(debtPositions[index].callBlock > block.number, "This loan has already been called.");
        // set the call block to the current block
        debtPositions[index].callBlock = block.number;
        // pull the call fee from the caller
        Credit(credit).burnFrom(msg.sender, callFee);
        // reduce the borrower's debt balance by the call fee
        debtPositions[index].debtBalance = debtPositions[index].debtBalance - callFee;
    }

    function seizeCollateral(uint256 index) public onlyGovernor {
        // require that the loan has been called
        require(debtPositions[index].callBlock > 0, "This loan has not been called.");
        // store the debt position in memory
        DebtPosition memory debtPosition = debtPositions[index];
        // delete the debt position
        delete debtPositions[index];
        // transfer the collateral token to the governor
        ERC20(collateralToken).transfer(governor, debtPosition.collateralBalance);
    }
}

contract Credit is ERC20 {

    // per LendingTerm, keep track of how many credits are available to borrow
    mapping(address => uint256) public availableCredit;

    address public governor;

    constructor(string memory _name, string memory _symbol, address _governor) ERC20(_name, _symbol, 18) {
        governor = _governor;
    }

    mapping(address => bool) public approvedLendingTerms;

    modifier onlyGovernor() {
        require(msg.sender == governor, "Only the governor can do that.");
        _;
    }

    // approve a lending term for credit allocation
    function approveLendingTerm(address lendingTerm) public onlyGovernor {
        approvedLendingTerms[lendingTerm] = true;
    }

    // define a new lending term
    function defineLendingTerm(address collateralToken, uint256 collateralRatio, uint256 interestRate, uint256 callFee, uint256 callPeriod) public returns (address) {
        CreditLendingTerm lendingTerm = new CreditLendingTerm(governor, address(this), collateralToken, collateralRatio, interestRate, callFee, callPeriod);
        return address(lendingTerm);
    }

    modifier onlyApprovedLendingTerm() {
        require(approvedLendingTerms[msg.sender], "You can't mint for that loan.");
        _;
    }

    function mintForLoan(address borrower, uint256 amount) public onlyApprovedLendingTerm {
        _mint(borrower, amount);
    }

    function mintForGovernor(address account, uint256 amount) public onlyGovernor {
        _mint(account, amount);
    }

    function burnFrom(address account, uint256 amount) public onlyApprovedLendingTerm {
        _burn(account, amount);
    }

}