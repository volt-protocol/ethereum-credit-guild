// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Loan.sol";
import "lib/solmate/src/tokens/ERC20.sol";

/*

System overview

GUILD holders can propose new lending terms and allocate debt limits
collateral holders can borrow credits
borrowers can repay credits
anyone can call loans by paying the call fee
anyone can bid on loans by paying the debt amount after the call period
the market price of credit depends on the nature of the collateral, the call fees, and the interest rates available
at start the system will target $1 by convention, but this is not hardcoded anywhere

*/

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
    uint256 public duration; // the time until the borrower's full collateral is available since the call time, in seconds

    constructor(address _core, uint256 _duration) {
        core = _core;
        duration = _duration;
    }

    modifier onlyGovernor() {
        require(msg.sender == Core(core).governor(), "Only the governor can do that.");
        _;
    }

    // inputs: the address of the lendingTerm, and the index of the debtPosition
    function bid(address terms, uint256 index) public {
        // require that the position is under liquidation
        require(CreditLendingTerm(terms).getLiquidationStatus(index), "The position is not under liquidation.");
        // require that the position is not past the duration
        require(block.timestamp - CreditLendingTerm(terms).getCallTime(index) <= duration, "The position is past the duration.");
        // calculate how much time has passed since the loan was called
        uint256 timePassed = block.timestamp - CreditLendingTerm(terms).getCallTime(index);
        // calculate the amount of collateral that is available to be claimed
        uint256 collateralAvailable = CreditLendingTerm(terms).getCollateralBalance(index) * timePassed / duration;
        // pull an amount of credits from the bidder equal to the debt amount
        ERC20(Core(core).credit()).transferFrom(msg.sender, 
                                                address(this), 
                                                CreditLendingTerm(terms).getDebtBalance(index) + 
                                                (CreditLendingTerm(terms).getDebtBalance(index) * Credit(Core(core).credit()).debtDiscountRate()));
        // transfer the collateral to the bidder
        ERC20(CreditLendingTerm(terms).collateralToken()).transfer(msg.sender, collateralAvailable);
        // transfer the remaining collateral to the borrower
        ERC20(CreditLendingTerm(terms).collateralToken()).transfer(CreditLendingTerm(terms).getBorrower(index), CreditLendingTerm(terms).getCollateralBalance(index) - collateralAvailable);
        // delete the debt position
        CreditLendingTerm(terms).deleteDebtPosition(index);
    }

    function bidPartial(address terms, uint256 index) public {
        // require that the position is under liquidation
        require(CreditLendingTerm(terms).getLiquidationStatus(index), "The position is not under liquidation.");
        // require that the position is past the duration
        require(block.timestamp - CreditLendingTerm(terms).getCallTime(index) > duration, "The position is not past the duration.");
        // calculate how much time has passed since the loan was called
        uint256 timePassed = block.timestamp - CreditLendingTerm(terms).getCallTime(index);
        // calculate the amount of debt the protocol will accept for partial repayment
        uint256 debtAccepted = (CreditLendingTerm(terms).getDebtBalance(index) + 
                                (CreditLendingTerm(terms).getDebtBalance(index) * (Credit(Core(core).credit()).debtDiscountRate()))) 
                                / timePassed 
                                * duration;
        // pull an amount of credits from the bidder equal to the debt accepted
        ERC20(Core(core).credit()).transferFrom(msg.sender, address(this), debtAccepted);
        // transfer the collateral to the bidder
        ERC20(CreditLendingTerm(terms).collateralToken()).transfer(msg.sender, CreditLendingTerm(terms).getCollateralBalance(index));
        // set the lending term to slashable
        CreditLendingTerm(terms).setSlashable(true);

        // calculate the ratio between the bad debt and the credit total supply
        uint256 badDebtRatio = ERC20(Core(core).credit()).totalSupply() / (CreditLendingTerm(terms).getDebtBalance(index) - debtAccepted);
        // update the debtDiscountRate of the credit token
        Credit(Core(core).credit()).setDebtDiscountRate(Credit(Core(core).credit()).debtDiscountRate() + (10**18 / badDebtRatio));

        // delete the debt position
        CreditLendingTerm(terms).deleteDebtPosition(index);
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
    uint256 public collateralRatio; // in terms of how many credits borrowable per collateral token
    uint256 public interestRate; // the interest rate is expressed in terms of a divisor of the loan per year
    // for example, if the interestRate is 20, that implies a 5% interest rate per year
    uint256 public callFee; // the call fee is expressed as a divisor of the collateral amount
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
        uint256 callTime;
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

    function getCallTime(uint256 index) public view returns (uint256) {
        return debtPositions[index].callTime;
    }

    function getLiquidationStatus(uint256 index) public view returns (bool) {
        return debtPositions[index].isInLiquidation;
    }

    DebtPosition[] public debtPositions;

    function setAvailableCredit(uint256 _availableCredit) public onlyGovernor {
        availableCredit = _availableCredit;
    }

    function setSlashable(bool _isSlashable) public onlyAuctionHouse {
        isSlashable = _isSlashable;
    }

    function borrowTokens(uint256 collateralAmount) public {
        require(collateralRatio * collateralAmount <= availableCredit, "Not enough credit available.");
        availableCredit = availableCredit - collateralRatio * collateralAmount;
        debtPositions.push(DebtPosition(msg.sender, collateralRatio * collateralAmount, collateralAmount, block.timestamp, 0, false));
        ERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        Credit(Core(core).credit()).mintForLoan(msg.sender, collateralRatio * collateralAmount);
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
        uint256 interest = debtPosition.debtBalance / interestRate * (block.timestamp - debtPosition.originationTime) / 365 days;

        // calculate the amount of credit tokens to repay accounting for the debt discount rate
        uint256 debtAccepted = debtPosition.debtBalance + interest + ((debtPosition.debtBalance + interest) * Credit(Core(core).credit()).debtDiscountRate());

        // burn credit tokens from the caller to repay the loan plus interest
        Credit(Core(core).credit()).burnFrom(msg.sender, debtAccepted);

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
        require(debtPositions[index].callTime == 0, "This loan has already been called.");
        // set the call block to the current block
        debtPositions[index].callTime = block.timestamp;
        // pull the call fee from the caller
        Credit(Core(core).credit()).burnFrom(msg.sender, debtPositions[index].debtBalance / callFee);
        // reduce the borrower's debt balance by the call fee
        debtPositions[index].debtBalance = debtPositions[index].debtBalance - (debtPositions[index].debtBalance / callFee);
    }

    function startLiquidation(uint256 index) public {
        // require that the loan has been called
        require(debtPositions[index].callTime > 0, "This loan has not been called.");

        // calculate the interest based on the time elapsed since origination
        uint256 interest = debtPositions[index].debtBalance / interestRate * (block.timestamp - debtPositions[index].originationTime) / 365 days;
        
        // update the debtPosition to include the interest
        debtPositions[index].debtBalance = debtPositions[index].debtBalance + interest;

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
    uint256 public debtDiscountRate; // the discount applied to the credit supply to account for bad debt
    // in terms of the difference 1 debt credit - 1 credit token (18 decimals)
    // zero means they are equal
    // 10**17 means that 1 credit token is worth 0.9 debt credit tokens
    // 10**18 means that 1 credit token is worth nothing

    constructor(string memory _name, string memory _symbol, address _core) ERC20(_name, _symbol, 18) {
        core = _core;
        debtDiscountRate = 0;
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

    // when bad debt occurs, the auctionhouse will mark down the ratio between the circulating credits and the credit debt of the loanbook
    // this ensures that the circulating supply of credit is always backed 1:1 by the outstanding debt
    // bad debt leads directly to a reduction in the unit value of credit, and does not produce incentives for a bank run,
    // since once a liquidation auction has started, any new loan being called and liquidated will resolve at a credit price
    // accounting for the auctions that resolve prior to the new loan's auction closing
    function setDebtDiscountRate(uint256 _debtDiscountRate) public onlyAuctionHouse {
        debtDiscountRate = _debtDiscountRate;
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