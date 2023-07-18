// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

/// @notice Lending Term contract of the Ethereum Credit Guild, a base implementation of
/// smart contract issuing CREDIT debt and escrowing collateral assets.
contract LendingTerm is CoreRef {
    using SafeERC20 for IERC20;

    // events for the lifecycle of loans that happen in the lending term
    event LoanBorrow(uint256 indexed when, bytes32 indexed loanId, address indexed borrower, uint256 collateralAmount, uint256 borrowAmount);
    event LoanCall(uint256 indexed when, bytes32 indexed loanId);
    event LoanRepay(uint256 indexed when, bytes32 indexed loanId);
    event LoanSeize(uint256 indexed when, bytes32 indexed loanId, bool loanCalled, bool collateralAuctioned);

    /// @notice reference number of seconds in 1 year
    uint256 public constant YEAR = 31557600;

    /// @notice minimum number of CREDIT to borrow when opening a new loan
    uint256 public constant MIN_BORROW = 100e18;

    /// @notice debt ceiling tolerance vs. ideal gauge weights to avoid deadlock situations and allow organic growth of borrows.
    /// Expressed as a percentage, with 18 decimals, e.g. 1.2e18 = 120% tolerance, meaning if GUILD holders' gauge weights
    /// would set a debt ceiling to 100 CREDIT, the issuance could go as high as 120 CREDIT.
    uint256 public constant GAUGE_CAP_TOLERANCE = 1.2e18;

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

    /// @notice if true, the governance has forgiven all loans, that can be immediately closed
    /// and marked as total losses in the system. This is meant for extreme events, where
    /// collateral assets are frozen and can't be sent to the auctionHouse for liquidations.
    bool public forgiveness = false;

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

    /// @notice current number of CREDIT issued in active loans on this term
    uint256 public issuance;

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

        // check that enough CREDIT is borrowed
        require(borrowAmount >= MIN_BORROW, "LendingTerm: borrow amount too low");

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
        uint256 _issuance = issuance;
        uint256 _postLoanIssuance = _issuance + borrowAmount;
        require(_postLoanIssuance <= hardCap, "LendingTerm: hardcap reached");
        uint256 _totalSupply = IERC20(creditToken).totalSupply();
        if (_totalSupply != 0) {
            uint256 debtCeiling = GuildToken(_guildToken).calculateGaugeAllocation(address(this), _totalSupply + borrowAmount);
            debtCeiling = debtCeiling * GAUGE_CAP_TOLERANCE / 1e18;
            require(_postLoanIssuance <= debtCeiling, "LendingTerm: debt ceiling reached");
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
        issuance = _postLoanIssuance;

        // mint CREDIT to the borrower
        RateLimitedCreditMinter(creditMinter).mint(msg.sender, borrowAmount);

        // pull the collateral from the borrower
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // emit event
        emit LoanBorrow(block.timestamp, loanId, msg.sender, collateralAmount, borrowAmount);
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
        uint256 creditToPullFromBorrower = loanDebt;
        if (callTime != 0 && block.timestamp <= callTime + callPeriod) {
            creditToPullFromBorrower -= getLoanCallFee(loanId);
        }
        
        // pull the CREDIT owed and refill the buffer of available CREDIT mints
        address _creditToken = creditToken;
        IERC20(_creditToken).transferFrom(msg.sender, address(this), creditToPullFromBorrower);
        // loanDebt >= creditToPullFromBorrower but the extra CREDIT should sit on the
        // LendingTerm contract from the previous call() call (provided by loan caller).
        RateLimitedCreditMinter(creditMinter).replenishBuffer(loanDebt);
        CreditToken(_creditToken).burn(loanDebt);

        // report profit
        GuildToken(guildToken).notifyPnL(address(this), pnl);

        // close the loan
        loan.closeTime = block.timestamp;
        issuance -= loan.borrowAmount;

        // return the collateral to the borrower
        IERC20(collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        // emit event
        emit LoanRepay(block.timestamp, loanId);
    }

    /// @notice call a list of loans, borrower has `callPeriod` seconds to repay the loan,
    /// or their collateral will be seized. This will pull the CREDIT call fee from `msg.sender`.
    function call(bytes32[] memory loanIds) public {
        uint256 creditToPullForCallFees = 0;
        for (uint256 i = 0; i < loanIds.length; i++) {
            bytes32 loanId = loanIds[i];
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
        
            // calculate the call fee
            creditToPullForCallFees += loan.borrowAmount * callFee / 1e18;
        
            // set the call info
            loan.caller = msg.sender;
            loan.callTime = block.timestamp;

            // emit event
            emit LoanCall(block.timestamp, loanId);
        }

        // pull the call fees from caller
        IERC20(creditToken).transferFrom(msg.sender, address(this), creditToPullForCallFees);
    }

    /// @notice call a single loan.
    function call(bytes32 loanId) external {
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;
        call(loanIds);
    }

    /// @notice seize the collateral of an array of loans, to repay outstanding debt.
    /// Under normal conditions, the loans should be call()'d first, to give the borrower an opportunity to repay (the 'call period').
    /// Conditions that allow to skip calling a loan before seizing its collateral :
    /// - forgiving all loans of a lending term (privileged role in the system)
    /// - offboading of a lending term (privileged role in the system)
    /// - issuance of lending term above hardcap set by governance
    function seize(bytes32[] memory loanIds, bool[] memory skipCall) public {
        uint256 _newIssuance = issuance;
        address _auctionHouse = auctionHouse;
        uint256 creditToSendToAuctionHouse = 0;
        for (uint256 i = 0; i < loanIds.length; i++) {
            bytes32 loanId = loanIds[i];
            Loan storage loan = loans[loanId];

            // check that the loan exists
            require(loan.originationTime != 0, "LendingTerm: loan not found");

            // check that the loan is not already closed
            require(loan.closeTime == 0, "LendingTerm: loan closed");

            // conditions that allow seizing the collateral of a loan without waiting for the call period to elapse
            bool canSkipCall = false;
            if (skipCall[i]) {
                canSkipCall = _newIssuance > hardCap || core().hasRole(CoreRoles.TERM_OFFBOARD, msg.sender);
            }

            // set the call info, if not set
            uint256 _callTime = loan.callTime;
            bool loanCalled = _callTime != 0;
            if (loanCalled) {
                // check that the call period has elapsed
                if (!canSkipCall) {
                    require(block.timestamp >= loan.callTime + callPeriod, "LendingTerm: call period in progress");
                }
                creditToSendToAuctionHouse += getLoanCallFee(loanId);
            } else {
                require(canSkipCall, "LendingTerm: loan not called");
                loan.caller = msg.sender;
                loan.callTime = block.timestamp;
            }

            // close the loan
            uint256 loanDebt = getLoanDebt(loanId);
            loans[loanId].closeTime = block.timestamp;
            uint256 _borrowAmount = loan.borrowAmount;
            _newIssuance -= _borrowAmount;

            if (forgiveness) {
                // mark loans as total losses
                int256 pnl = -int256(_borrowAmount);
                GuildToken(guildToken).notifyPnL(address(this), pnl);

                // emit event
                emit LoanSeize(block.timestamp, loanId, loanCalled, false);
            } else {
                // auction the loan collateral
                IERC20(collateralToken).safeApprove(_auctionHouse, loan.collateralAmount);
                AuctionHouse(_auctionHouse).startAuction(loanId, loanDebt, loanCalled);

                // emit event
                emit LoanSeize(block.timestamp, loanId, loanCalled, true);
            }
        }

        // send CREDIT from the call fees to the auction house
        if (creditToSendToAuctionHouse != 0) {
            IERC20(creditToken).transfer(_auctionHouse, creditToSendToAuctionHouse);
        }

        // update issuance
        issuance = _newIssuance;
    }

    /// @notice seize a single loan without attempt to skip the call period.
    function seize(bytes32 loanId) external {
        bytes32[] memory loanIds = new bytes32[](1);
        bool[] memory skipCall = new bool[](1);
        loanIds[0] = loanId;
        skipCall[0] = false;
        seize(loanIds, skipCall);
    }

    /// @notice forgive all loans. This will allow all loans to be closed (through the `seize()`
    /// function call) and marked as total losses in the system, without attempting to transfer
    /// the collateral tokens to the auction house. This is meant for extreme events where collateral
    /// assets are frozen and can't be transferred within or out of the system anymore.
    function forgiveAllLoans() external {
        require(canAutomaticallyForgive() || core().hasRole(CoreRoles.TERM_OFFBOARD, msg.sender), "LendingTerm: cannot forgive");
        forgiveness = true;
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

    /// @notice automatic criteria for loan forgiveness, for use in inheriting contracts.
    function canAutomaticallyForgive() public virtual view returns (bool) {
        return false;
    }
}