// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Loan.sol";
import "lib/solmate/src/tokens/ERC20.sol";

contract Core {
    address public governor;
    address public credit;
    address public guild;
    address public auctionHouse;

    // in the constructor, create instances of each system contract and take only the governor address as an input
    constructor(address _governor, uint256 _duration, uint256 _voteRatio) {
        governor = _governor;
        credit = address(new Credit("Credit", "CREDIT", address(this)));
        guild = address(new Guild(address(this), _voteRatio)); 
        auctionHouse = address(new AuctionHouse(address(this), _duration));
    }

}

contract AuctionHouse {
    address public core;
    uint256 public duration;

    constructor(address _core, uint256 _duration) {
        core = _core;
        duration = _duration;
    }

    modifier onlyGovernor() {
        require(msg.sender == Core(core).governor(), "Only the governor can do that.");
        _;
    }

    // starting from zero tokens, increment up the amount of collateral offered in exchange for enough credit to pay off the debt
    function bid(address terms, uint256 position) public {
        // at the call block, auction offers none of the collateral, and increments each block after by the increment
        // the auction ends when an amount of the collateral is accepted in exchange for enough credit to pay off the debt,
        // or when a partial repayment is accepted
        uint256 amountToAccept = block.number - CreditLendingTerm(terms).getCallBlock(position) * CreditLendingTerm(terms).getCollateralBalance(position) / duration;

        // if the amount of collateral  is less than or equal to the available collateralAmount,
        if (amountToAccept <= CreditLendingTerm(terms).getCollateralBalance(position)) {
            // send that amount of collateral from this contract to the bidder and pull credit tokens from the bidder to this contract to repay the debt
            ERC20(CreditLendingTerm(terms).collateralToken()).transfer(msg.sender, amountToAccept);
            // pull credit tokens from the bidder equal to the debt amount
            ERC20(Core(core).credit()).transferFrom(msg.sender, address(this), CreditLendingTerm(terms).getDebtBalance(position));
            // send any remaining collateral to the borrower
            ERC20(CreditLendingTerm(terms).collateralToken()).transfer(CreditLendingTerm(terms).getBorrower(position), CreditLendingTerm(terms).getCollateralBalance(position) - amountToAccept);
            // burn the credit tokens
            Credit(Core(core).credit()).burnFromAuctionHouse(CreditLendingTerm(terms).getDebtBalance(position));
        }

        // otherwise, if the amount of collateral is greater than the available collateralAmount,
        else {
            // send the entire collateralAmount from this contract to the bidder and pull credit tokens from the bidder to this contract to repay the debt
            ERC20(CreditLendingTerm(terms).collateralToken()).transfer(msg.sender, CreditLendingTerm(terms).getCollateralBalance(position));
            // pull credit tokens from the bidder equal to the debt amount times the collateralAmount divided by the amountToAccept
            ERC20(Core(core).credit()).transferFrom(
                msg.sender, 
                address(this), 
                (CreditLendingTerm(terms).getDebtBalance(position) * CreditLendingTerm(terms).getCollateralBalance(position) / amountToAccept));
            // burn the credit tokens
            Credit(Core(core).credit()).burnFromAuctionHouse(CreditLendingTerm(terms).getDebtBalance(position) * CreditLendingTerm(terms).getCollateralBalance(position) / amountToAccept);
            // set the isSlashable flag to true on the LendingTerm contract
            // in this MVP, if any bad debt occurs in a lending term, it is defunct and voters there can be slashed
            // governance may reenable it later if appropriate
            CreditLendingTerm(terms).setIsSlashable(true);
        }

        // delete the associated debt position
        CreditLendingTerm(terms).deleteDebtPosition(position);
    }
}

contract Guild is ERC20 {
    address public core;
    uint256 public voteRatio; // the amount of credit allocated per GUILD token when voting

    modifier onlyGovernor() {
        require(msg.sender == Core(core).governor(), "Only the governor can do that.");
        _;
    }

    constructor(address _core, uint256 _voteRatio) ERC20("Guild", "GUILD", 18) {
        core = _core;
        voteRatio = _voteRatio;
    }

    function mint(address account, uint256 amount) public onlyGovernor {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public onlyGovernor {
        _burn(account, amount);
    }

    function setVoteRatio(uint256 _voteRatio) public onlyGovernor {
        voteRatio = _voteRatio;
    }

}

contract CreditLendingTerm {

    address public core;
    address public collateralToken;
    uint256 public collateralRatio;
    uint256 public interestRate;
    uint256 public callFee;
    uint256 public callPeriod;

    uint256 public availableCredit;
    bool public isSlashable;

    // keep track of how many GUILD tokens are voting for this lending term per address
    mapping(address => uint256) public votes;

    modifier onlyGovernor() {
        require(msg.sender == Core(core).governor(), "Only the governor can do that.");
        _;
    }

    modifier onlyAuctionHouse() {
        require(msg.sender == Core(core).auctionHouse(), "Only the auction house can do that.");
        _;
    }

    constructor(address _core, address _collateralToken, uint256 _collateralRatio, uint256 _interestRate, uint256 _callFee, uint256 _callPeriod) {
        core = _core;
        collateralToken = _collateralToken;
        collateralRatio = _collateralRatio;
        interestRate = _interestRate;
        callFee = _callFee;
        callPeriod = _callPeriod;
        isSlashable = false;
    }

    struct DebtPosition {
        address borrower;
        uint256 debtBalance;
        uint256 collateralBalance;
        uint256 originationTime;
        uint256 callBlock;
        bool isInLiquidation;
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

    function setAvailableCredit(uint256 _availableCredit) public onlyGovernor {
        availableCredit = _availableCredit;
    }

    function setIsSlashable(bool _isSlashable) public onlyAuctionHouse {
        isSlashable = _isSlashable;
    }

    function borrowTokens(uint256 collateralAmount, uint256 borrowAmount) public {
        require(collateralRatio * collateralAmount >= borrowAmount, "You can't borrow that much.");
        require(borrowAmount <= availableCredit, "Not enough credit available.");
        availableCredit = availableCredit - borrowAmount;
        debtPositions.push(DebtPosition(msg.sender, borrowAmount, collateralAmount, block.timestamp, block.number + callPeriod, false));
        ERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        Credit(Core(core).credit()).mintForLoan(msg.sender, borrowAmount);
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
        Credit(Core(core).credit()).burnFrom(msg.sender, debtPosition.debtBalance + interest);

        // transfer the collateral token to the borrower
        ERC20(collateralToken).transfer(debtPosition.borrower, debtPosition.collateralBalance);

        // increment the available credit
        availableCredit = availableCredit + debtPosition.debtBalance;
    }

    function deleteDebtPosition(uint256 index) public onlyAuctionHouse {
        delete debtPositions[index];
    }

    function callPosition(uint256 index) public {
        // require that the loan has not yet been called
        require(debtPositions[index].callBlock > block.number, "This loan has already been called.");
        // set the call block to the current block
        debtPositions[index].callBlock = block.number;
        // pull the call fee from the caller
        Credit(Core(core).credit()).burnFrom(msg.sender, callFee);
        // reduce the borrower's debt balance by the call fee
        debtPositions[index].debtBalance = debtPositions[index].debtBalance - callFee;
    }

    function startLiquidation(uint256 index) public {
        // require that the loan has been called
        require(debtPositions[index].callBlock > 0, "This loan has not been called.");

        // transfer the collateral token to the auction house
        ERC20(collateralToken).transfer(Core(core).auctionHouse(), debtPositions[index].collateralBalance);

        // set the liquidation flag so votes can't be withdrawn
        debtPositions[index].isInLiquidation = true;
    }

    function voteForLendingTerm(uint256 amount) public {
        // require the term is not slashable
        require(!isSlashable, "This term is slashable.");
        // transfer the GUILD tokens from the caller to this contract
        ERC20(Core(core).guild()).transferFrom(msg.sender, address(this), amount);
        // increment the caller's vote balance
        votes[msg.sender] = votes[msg.sender] + amount;
        // increment the available credit based on the vote ratio
        availableCredit = availableCredit + amount * Guild(Core(core).guild()).voteRatio();
    }

    // allow withdrawing votes only if there is available credit
    function withdrawVotes(uint256 amount) public {
        // require the loan is not slashable
        require(!isSlashable, "This term is slashable.");
        // require that the caller has enough votes
        require(votes[msg.sender] >= amount, "You don't have enough votes.");
        // require that the available credit is greater than the amount of votes being withdrawn
        require(availableCredit >= amount * Guild(Core(core).guild()).voteRatio(), "There is not enough credit available.");
        // decrement the caller's vote balance
        votes[msg.sender] = votes[msg.sender] - amount;
        // decrement the available credit based on the vote ratio
        availableCredit = availableCredit - amount * Guild(Core(core).guild()).voteRatio();
        // transfer the GUILD tokens from this contract to the caller
        ERC20(Core(core).guild()).transfer(msg.sender, amount);
    } 
}

contract Credit is ERC20 {

    // per LendingTerm, keep track of how many credits are available to borrow
    mapping(address => uint256) public availableCredit;

    address public core;

    constructor(string memory _name, string memory _symbol, address _core) ERC20(_name, _symbol, 18) {
        core = _core;
    }

    mapping(address => bool) public approvedLendingTerms;

    modifier onlyGovernor() {
        require(msg.sender == Core(core).governor(), "Only the governor can do that.");
        _;
    }

    modifier onlyAuctionHouse() {
        require(msg.sender == Core(core).auctionHouse(), "Only the auction house can do that.");
        _;
    }

    // approve a lending term for credit allocation
    function approveLendingTerm(address lendingTerm) public onlyGovernor {
        approvedLendingTerms[lendingTerm] = true;
    }

    // define a new lending term
    function defineLendingTerm(address collateralToken, uint256 collateralRatio, uint256 interestRate, uint256 callFee, uint256 callPeriod) public returns (address) {
        CreditLendingTerm lendingTerm = new CreditLendingTerm(core, collateralToken, collateralRatio, interestRate, callFee, callPeriod);
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

    function burnFromAuctionHouse(uint256 amount) public onlyAuctionHouse {
        _burn(Core(core).auctionHouse(), amount);
    }

}