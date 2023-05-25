// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

// TODO:
// - Add a debtDiscountRate in CREDIT to mark down when bad debt occur, and use it to correct all
//   loan debt amounts in LendingTerm.
// - Consider if only borrow() should be pausable, or also repay(), call(), and seize()
// - Add events
// - safeTransfer on collateralToken
// - public constant DUST amount: minimum amount of CREDIT to borrow to open new loans
// - add tolerance to gauge imbalance (debtCeiling in borrow()) to avoid deadlock situations and allow organic growth of borrows
// - refactor in smaller internal functions, so that child contracts can reuse code more conveniently

contract LendingTerm is CoreRef {

    /// @notice reference number of seconds in 1 year
    uint256 public constant YEAR = 31557600;

    /// @notice reference to the GUILD token
    address public immutable guildToken;

    /// @notice reference to the auction house contract where
    /// the collateral of loans is sent if borrowers do not repay
    /// their CREDIT debt during the call period.
    address public auctionHouse;

    /// @notice reference to the credit minter contract
    address public immutable creditMinter;

    /// @notice reference to the CREDIT token
    address public immutable creditToken;

    /// @notice reference to the collateral token
    address public immutable collateralToken;

    /// @notice number of CREDIT loaned per collateral token.
    /// @dev be mindful of the decimals here, because if collateral
    /// token doesn't have 18 decimals, this variable is used to scale
    /// the decimals.
    /// For example, for USDC collateral, this variable should be around
    /// ~1e30, to allow 1e6 * 1e30 / 1e18 ~= 1e18 CREDIT to be borrowed for
    /// each 1e6 units (1 USDC) of collateral, if CREDIT is targeted to be
    /// worth around 1 USDC.
    uint256 public immutable creditPerCollateralToken;

    /// @notice interest rate paid by the borrower, expressed as an APR
    /// with 18 decimals (0.01e18 = 1% APR). The base for 1 year is the YEAR constant.
    uint256 public immutable interestRate;

    /// @notice the call fee is a small amount of CREDIT provided by the caller
    /// when the loan is called.
    /// The call fee is expressed as a percentage of the borrowAmount, with 18
    /// decimals, e.g. 0.05e18 = 5% of the borrowed amount.
    /// When the loan closes, one of the following situations happen :
    /// - The borrower repay the CREDIT debt during the call period => caller
    ///   forfeit their CREDIT and borrower is compensated with the call fee
    ///   (their CREDIT debt is minored by the CREDIT paid in the call fee).
    /// - The borrower does not repay during the call period, collateral is
    ///   auctioned until enough CREDIT is recovered to cover debt + call fee.
    ///   If there is more than `ltvBuffer` collateral left, the borrower
    ///   gets the call fee. Otherwise, the caller recover the call fee.
    ///   If bad debt is created (after selling all the collateral, not enough
    ///   CREDIT is recovered to cover the debt + the call fee), the caller is
    ///   reimbursed in priority before the protocol.
    /// The borrower can close the loan (repay) without call period & call fee.
    uint256 public immutable callFee;

    /// @notice call period in seconds. Loans are running forever until borrower
    /// repays or someone calls the loan, which starts the call period. During the
    /// call period, the borrower can reimburse the CREDIT debt (minus call fee) and
    /// recover their collateral. If the borrower does not replay the CREDIT debt
    /// during the call period, the loan is closed by seizing the collateral
    /// and it is sold in an auction.
    uint256 public immutable callPeriod;

    /// @notice the absolute maximum amount of debt this lending term can create
    /// (sum of CREDIT minted), regardless of the gauge allocations.
    uint256 public hardCap;

    /// @notice the LTV buffer, expressed as a percentage with 18 decimals.
    /// Example: for a value of 0.1e18 (10%), the LTV buffer will waive the call fee
    /// (reimburse CREDIT to the caller) if less than 10% of the collateral of the borrower
    /// is left after a collateral auction, or if bad debt is created.
    uint256 public immutable ltvBuffer;

    struct Loan {
        address borrower;
        uint256 borrowAmount;
        uint256 collateralAmount;
        address caller; // a caller of 0 indicates that the loan has not been called
        uint256 callTime; // a call time of 0 indicates that the loan has not been called
        uint256 originationTime; // the time the loan was initiated
        uint256 closeTime; // the time the loan was closed (repaid or liquidated)
    }

    /// @notice the list of all loans that existed or are still active
    mapping(bytes32=>Loan) public loans;

    /// @notice total number of CREDIT borrowed, this value is stale unless
    /// someone opened or closed a loan in the same block
    uint256 public totalBorrowsStored;

    /// @notice last update timestamp of `totalBorrowsStored`
    uint256 public totalBorrowsLastUpdate;

    struct LendingTermParams {
        address collateralToken;
        uint256 creditPerCollateralToken;
        uint256 interestRate;
        uint256 callFee;
        uint256 callPeriod;
        uint256 hardCap;
        uint256 ltvBuffer;
    }

    constructor(
        address _core,
        address _guildToken,
        address _auctionHouse,
        address _creditMinter,
        address _creditToken,
        LendingTermParams memory params
    ) CoreRef(_core) {
        guildToken = _guildToken;
        auctionHouse = _auctionHouse;
        creditMinter = _creditMinter;
        creditToken = _creditToken;
        collateralToken = params.collateralToken;
        creditPerCollateralToken = params.creditPerCollateralToken;
        interestRate = params.interestRate;
        callFee = params.callFee;
        callPeriod = params.callPeriod;
        hardCap = params.hardCap;
        ltvBuffer = params.ltvBuffer;
    }

    /// @notice get a loan
    function getLoan(bytes32 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    /// @notice total outstanding borrows, including interests
    function totalBorrows() public view returns (uint256) {
        uint256 _totalBorrowsStored = totalBorrowsStored;
        uint256 interestPerYear = _totalBorrowsStored * interestRate / 1e18;
        return _totalBorrowsStored + interestPerYear * (block.timestamp - totalBorrowsLastUpdate) / YEAR;
    }

    /// @notice call fee of a loan, in CREDIT base units
    function getLoanCallFee(bytes32 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 originationTime = loan.originationTime;

        if (originationTime == 0) {
            return 0;
        }

        if (loan.closeTime != 0) {
            return 0;
        }

        return loan.borrowAmount * callFee / 1e18;
    }

    /// @notice outstanding borrowed amount of a loan, including interests
    function getLoanDebt(bytes32 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 originationTime = loan.originationTime;

        if (originationTime == 0) {
            return 0;
        }

        if (loan.closeTime != 0) {
            return 0;
        }

        // compute interest owed
        uint256 borrowAmount = loan.borrowAmount;
        uint256 interest = borrowAmount * interestRate * (block.timestamp - originationTime) / YEAR / 1e18;
        uint256 loanDebt = borrowAmount + interest;

        return loanDebt;
    }

    /// @notice initiate a new loan
    function borrow(
        uint256 borrowAmount,
        uint256 collateralAmount
    ) external whenNotPaused returns (bytes32 loanId) {
        require(borrowAmount != 0, "LendingTerm: cannot borrow 0");
        require(collateralAmount != 0, "LendingTerm: cannot stake 0");

        loanId = keccak256(abi.encode(msg.sender, address(this), block.timestamp));

        // check that the loan doesn't already exist
        require(loans[loanId].originationTime == 0, "LendingTerm: loan exists");

        // check that enough collateral is provided
        uint256 maxBorrow = collateralAmount * creditPerCollateralToken / 1e18;
        require(borrowAmount <= maxBorrow, "LendingTerm: not enough collateral");

        // check that ltvBuffer is respected
        uint256 maxBorrowLtv = maxBorrow * 1e18 / (1e18 + ltvBuffer);
        require(borrowAmount <= maxBorrowLtv, "LendingTerm: not enough LTV buffer");

        // check that this lending term is active
        address _guildToken = guildToken;
        require(GuildToken(_guildToken).isGauge(address(this)), "LendingTerm: terms unavailable");

        // check the debt ceiling & hardcap
        uint256 _totalBorrows = totalBorrows();
        require(_totalBorrows + borrowAmount <= hardCap, "LendingTerm: hardcap reached");
        uint256 _totalSupply = ERC20(creditToken).totalSupply();
        if (_totalSupply != 0) {
            uint256 debtCeiling = GuildToken(_guildToken).calculateGaugeAllocation(address(this), _totalSupply + borrowAmount);
            require(_totalBorrows + borrowAmount <= debtCeiling, "LendingTerm: debt ceiling reached");
        }

        // save loan in state
        loans[loanId] = Loan({
            borrower: msg.sender,
            borrowAmount: borrowAmount,
            collateralAmount: collateralAmount,
            caller: address(0),
            callTime: 0,
            originationTime: block.timestamp,
            closeTime: 0
        });

        // mint CREDIT to the borrower
        RateLimitedCreditMinter(creditMinter).mint(msg.sender, borrowAmount);

        // update total borrows
        totalBorrowsStored = _totalBorrows + borrowAmount;
        totalBorrowsLastUpdate = block.timestamp;

        // pull the collateral from the borrower
        ERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
    }

    /// @notice repay an open loan
    function repay(bytes32 loanId) external {
        Loan storage loan = loans[loanId];

        // check the loan is open
        uint256 originationTime = loan.originationTime;
        require(originationTime != 0, "LendingTerm: loan not found");
        require(originationTime < block.timestamp, "LendingTerm: loan opened in same block");
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // compute interest owed
        uint256 loanDebt = getLoanDebt(loanId);
        int256 pnl = int256(loanDebt) - int256(loan.borrowAmount);
    
        // if the loan is called and we are within the call period, deduce the callFee from
        // the amount of debt to repay
        uint256 callTime = loan.callTime;
        if (callTime != 0 && block.timestamp <= callTime + callPeriod) {
            loanDebt -= getLoanCallFee(loanId);
        }
        
        // pull the total CREDIT owed and refill the buffer of available CREDIT mints
        address _creditToken = creditToken;
        ERC20(_creditToken).transferFrom(msg.sender, address(this), loanDebt);
        RateLimitedCreditMinter(creditMinter).replenishBuffer(loanDebt);
        CreditToken(_creditToken).burn(loanDebt);

        // report profit
        GuildToken(guildToken).notifyPnL(address(this), pnl);

        // close the loan
        loan.closeTime = block.timestamp;

        // update total borrows
        totalBorrowsStored = totalBorrows() - loanDebt;
        totalBorrowsLastUpdate = block.timestamp;

        // return the collateral to the borrower
        ERC20(collateralToken).transfer(loan.borrower, loan.collateralAmount);
    }

    /// @notice call a loan, borrower has `callPeriod` seconds to repay the loan,
    /// or their collateral will be seized.
    function call(bytes32 loanId) external {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        uint256 _originationTime = loan.originationTime;
        require(_originationTime != 0, "LendingTerm: loan not found");

        // check that the loan has not been created in the same block
        require(_originationTime < block.timestamp, "LendingTerm: loan opened in same block");

        // check that the loan is not already called
        require(loan.callTime == 0, "LendingTerm: loan called");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");
    
        // calculate the fee, pull it from caller, and burn the CREDIT
        uint256 loanCallFee = loan.borrowAmount * callFee / 1e18;

        // pull the fee from caller and burn it
        ERC20(creditToken).transferFrom(msg.sender, address(this), loanCallFee);
        RateLimitedCreditMinter(creditMinter).replenishBuffer(loanCallFee);
        CreditToken(creditToken).burn(loanCallFee);
    
        // set the call info
        loan.caller = msg.sender;
        loan.callTime = block.timestamp;
    }

    /// @notice seize the collateral of a loan after the call period, to repay outstanding debt.
    function seize(bytes32 loanId) external {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        require(loan.originationTime != 0, "LendingTerm: loan not found");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // check that the loan has been called
        require(loan.callTime > 0, "LendingTerm: loan not called");

        // check that the call period has elapsed
        require(block.timestamp >= loan.callTime + callPeriod, "LendingTerm: call period in progress");

        // update total borrows
        uint256 loanDebt = getLoanDebt(loanId);
        totalBorrowsStored = totalBorrows() - loanDebt;
        totalBorrowsLastUpdate = block.timestamp;

        // close the loan
        loans[loanId].closeTime = block.timestamp;

        // auction the loan collateral
        address _auctionHouse = auctionHouse;
        ERC20(collateralToken).approve(_auctionHouse, loan.collateralAmount);
        AuctionHouse(_auctionHouse).startAuction(loanId, loanDebt, true);
    }

    /// @notice used to call() + seize() a list of loans for emergency offboarding of a lending term.
    /// Loans that are already called are not called again.
    /// Does not collect the call fee.
    function offboard(bytes32[] memory loanIds) external onlyCoreRole(CoreRoles.TERM_OFFBOARD) {
        uint256 _newTotalBorrows = totalBorrows();
        for (uint256 i = 0; i < loanIds.length; i++) {
            bytes32 loanId = loanIds[i];
            Loan storage loan = loans[loanId];

            // check that the loan exists
            require(loan.originationTime != 0, "LendingTerm: loan not found");

            // check that the loan is not already closed
            require(loan.closeTime == 0, "LendingTerm: loan closed");

            // set the call info, if not set
            bool loanCalled = false;
            if (loan.callTime != 0) {
                loanCalled = true;
            } else {
                loan.caller = msg.sender;
                loan.callTime = block.timestamp;
            }

            // close the loan
            uint256 loanDebt = getLoanDebt(loanId);
            _newTotalBorrows -= loanDebt;
            loans[loanId].closeTime = block.timestamp;

            // auction the loan collateral
            address _auctionHouse = auctionHouse;
            ERC20(collateralToken).approve(_auctionHouse, loan.collateralAmount);
            AuctionHouse(_auctionHouse).startAuction(loanId, loanDebt, loanCalled);
        }

        // update total borrows
        totalBorrowsStored = _newTotalBorrows;
        totalBorrowsLastUpdate = block.timestamp;
    }

    /// @notice set the address of the auction house.
    /// governor-only, to allow full governance to update the auction mechanisms.
    function setAuctionHouse(address _newValue) external onlyCoreRole(CoreRoles.GOVERNOR) {
        auctionHouse = _newValue;
    }

    /// @notice set the hardcap of CREDIT mintable in this term.
    /// allows to update a term's arbitrary hardcap without doing a gauge & loans migration.
    function setHardCap(uint256 _newValue) external onlyCoreRole(CoreRoles.TERM_HARDCAP) {
        hardCap = _newValue;
    }
}
