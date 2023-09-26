// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

/// @notice Lending Term contract of the Ethereum Credit Guild, a base implementation of
/// smart contract issuing CREDIT debt and escrowing collateral assets.
contract LendingTerm is CoreRef {
    using SafeERC20 for IERC20;

    // events for the lifecycle of loans that happen in the lending term
    /// @notice emitted when new loans are opened (mint debt to borrower, pull collateral from borrower).
    event LoanBorrow(
        uint256 indexed when,
        bytes32 indexed loanId,
        address indexed borrower,
        uint256 collateralAmount,
        uint256 borrowAmount
    );
    /// @notice emitted when a loan is called (repayer has `callPeriod` seconds to repay at a discount).
    event LoanCall(uint256 indexed when, bytes32 indexed loanId);
    /// @notice emitted when a loan is closed (repay, seize, forgive).
    /// closeType enum : 0 = repay, 1 = seize, 2 = forgive.
    /// if closeType == 1 (seize), there will be a subsequent LoanBid event.
    event LoanClose(
        uint256 indexed when,
        bytes32 indexed loanId,
        uint8 indexed closeType,
        bool loanCalled
    );
    /// @notice emitted when there is a bid on a loan's collateral to liquidate the position.
    event LoanBid(
        uint256 indexed when,
        bytes32 indexed loanId,
        uint256 collateralSold,
        uint256 debtRecovered
    );
    /// @notice emitted when someone adds collateral to a loan
    event LoanAddCollateral(
        uint256 indexed when,
        bytes32 indexed loanId,
        address indexed borrower,
        uint256 collateralAmount
    );
    /// @notice emitted when someone partially repays a loan
    event LoanPartialRepay(
        uint256 indexed when,
        bytes32 indexed loanId,
        address indexed repayer,
        uint256 repayAmount
    );

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice reference number of seconds in 1 year
    uint256 public constant YEAR = 31557600;

    /// @notice minimum number of CREDIT to borrow when opening a new loan
    uint256 public constant MIN_BORROW = 100e18;

    /// @notice debt ceiling tolerance vs. ideal gauge weights to avoid deadlock situations and allow organic growth of borrows.
    /// Expressed as a percentage, with 18 decimals, e.g. 1.2e18 = 120% tolerance, meaning if GUILD holders' gauge weights
    /// would set a debt ceiling to 100 CREDIT, the issuance could go as high as 120 CREDIT.
    uint256 public constant GAUGE_CAP_TOLERANCE = 1.2e18;

    /// @notice reference to the ProfitManager
    address public immutable profitManager;

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

    /// @notice max number of debt tokens issued per collateral token.
    /// @dev be mindful of the decimals here, because if collateral
    /// token doesn't have 18 decimals, this variable is used to scale
    /// the decimals.
    /// For example, for USDC collateral, this variable should be around
    /// ~1e30, to allow 1e6 * 1e30 / 1e18 ~= 1e18 CREDIT to be borrowed for
    /// each 1e6 units (1 USDC) of collateral, if CREDIT is targeted to be
    /// worth around 1 USDC.
    uint256 public immutable maxDebtPerCollateralToken;

    /// @notice interest rate paid by the borrower, expressed as an APR
    /// with 18 decimals (0.01e18 = 1% APR). The base for 1 year is the YEAR constant.
    uint256 public immutable interestRate;

    /// @notice maximum delay, in seconds, between partial debt repayments.
    /// if set to 0, no periodic partial repayments are expected.
    /// if a partial repayment is missed (delay has passed), the loan
    /// can be called without paying the call fee.
    uint256 public immutable maxDelayBetweenPartialRepay;

    /// @notice minimum percent of the total debt (principal + interests) to
    /// repay during partial debt repayments.
    /// percentage is expressed with 18 decimals, e.g. 0.05e18 = 5% debt.
    uint256 public immutable minPartialRepayPercent;

    /// @notice timestamp of last partial repayment for a given loanId.
    /// during borrow(), this is initialized to the borrow timestamp, if
    /// maxDelayBetweenPartialRepay is != 0
    mapping(bytes32 => uint256) public lastPartialRepay;

    /// @notice the opening fee is a small amount of CREDIT provided by the borrower
    /// when the loan is opened.
    /// The call fee is expressed as a percentage of the borrowAmount, with 18
    /// decimals, e.g. 0.05e18 = 5% of the borrowed amount.
    uint256 public immutable openingFee;

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
        uint256 creditMultiplierOpen; // creditMultiplier when loan was opened
        address caller; // a caller of 0 indicates that the loan has not been called
        uint256 callTime; // a call time of 0 indicates that the loan has not been called
        uint256 originationTime; // the time the loan was initiated
        uint256 closeTime; // the time the loan was closed (repaid or seized)
        uint256 debtWhenSeized; // the debt when the loan collateral has been seized
        uint256 bidTime; // the time of auction bid when collateral was liquidated
    }

    /// @notice the list of all loans that existed or are still active
    mapping(bytes32 => Loan) public loans;

    /// @notice current number of CREDIT issued in active loans on this term
    uint256 public issuance;

    struct LendingTermParams {
        address collateralToken;
        uint256 maxDebtPerCollateralToken;
        uint256 interestRate;
        uint256 maxDelayBetweenPartialRepay;
        uint256 minPartialRepayPercent;
        uint256 openingFee;
        uint256 callFee;
        uint256 callPeriod;
        uint256 hardCap;
        uint256 ltvBuffer;
    }

    constructor(
        address _core,
        address _profitManager,
        address _guildToken,
        address _auctionHouse,
        address _creditMinter,
        address _creditToken,
        LendingTermParams memory params
    ) CoreRef(_core) {
        profitManager = _profitManager;
        guildToken = _guildToken;
        auctionHouse = _auctionHouse;
        creditMinter = _creditMinter;
        creditToken = _creditToken;
        collateralToken = params.collateralToken;
        maxDebtPerCollateralToken = params.maxDebtPerCollateralToken;
        interestRate = params.interestRate;
        maxDelayBetweenPartialRepay = params.maxDelayBetweenPartialRepay;
        minPartialRepayPercent = params.minPartialRepayPercent;
        openingFee = params.openingFee;
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

        return (loan.borrowAmount * callFee) / 1e18;
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
        uint256 interest = (borrowAmount *
            interestRate *
            (block.timestamp - originationTime)) /
            YEAR /
            1e18;
        uint256 loanDebt = borrowAmount + interest;
        uint256 creditMultiplier = ProfitManager(profitManager).creditMultiplier();
        uint256 _creditMultiplierOpen = loan.creditMultiplierOpen;
        loanDebt = loanDebt * _creditMultiplierOpen / creditMultiplier;

        return loanDebt;
    }

    /// @notice returns true if the term has a maximum delay between partial repays
    /// and the loan has passed the delay for partial repayments.
    function partialRepayDelayPassed(
        bytes32 loanId
    ) public view returns (bool) {
        // if no periodic partial repays are expected, always return false
        if (maxDelayBetweenPartialRepay == 0) return false;

        // if loan doesn't exist, return false
        if (loans[loanId].originationTime == 0) return false;

        // if loan is closed, return false
        if (loans[loanId].closeTime != 0) return false;

        // return true if delay is passed
        return
            lastPartialRepay[loanId] <
            block.timestamp - maxDelayBetweenPartialRepay;
    }

    /// @notice initiate a new loan
    function _borrow(
        address borrower,
        uint256 borrowAmount,
        uint256 collateralAmount
    ) internal returns (bytes32 loanId) {
        require(borrowAmount != 0, "LendingTerm: cannot borrow 0");
        require(collateralAmount != 0, "LendingTerm: cannot stake 0");

        loanId = keccak256(
            abi.encode(borrower, address(this), block.timestamp)
        );

        // check that the loan doesn't already exist
        require(loans[loanId].originationTime == 0, "LendingTerm: loan exists");

        // check that enough CREDIT is borrowed
        require(
            borrowAmount >= MIN_BORROW,
            "LendingTerm: borrow amount too low"
        );

        // check that enough collateral is provided
        uint256 maxBorrow = (collateralAmount * maxDebtPerCollateralToken) /
            1e18;
        uint256 creditMultiplier = ProfitManager(profitManager).creditMultiplier();
        maxBorrow = maxBorrow * 1e18 / creditMultiplier;
        require(
            borrowAmount <= maxBorrow,
            "LendingTerm: not enough collateral"
        );

        // check that ltvBuffer is respected
        uint256 maxBorrowLtv = (maxBorrow * 1e18) / (1e18 + ltvBuffer);
        require(
            borrowAmount <= maxBorrowLtv,
            "LendingTerm: not enough LTV buffer"
        );

        // check the hardcap
        uint256 _issuance = issuance;
        uint256 _postBorrowIssuance = _issuance + borrowAmount;
        require(_postBorrowIssuance <= hardCap, "LendingTerm: hardcap reached");

        // check the debt ceiling
        uint256 _totalSupply = CreditToken(creditToken).totalSupply();
        uint256 debtCeiling = (GuildToken(guildToken).calculateGaugeAllocation(
            address(this),
            _totalSupply + borrowAmount
        ) * GAUGE_CAP_TOLERANCE) / 1e18;
        if (_totalSupply == 0) {
            // if the lending term is deprecated, `calculateGaugeAllocation` will return 0, and the borrow
            // should revert because the debt ceiling is reached (no borrows should be allowed anymore).
            // first borrow in the system does not check proportions of issuance, just that the term is not deprecated.
            require(debtCeiling != 0, "LendingTerm: debt ceiling reached");
        } else {
            require(
                _postBorrowIssuance <= debtCeiling,
                "LendingTerm: debt ceiling reached"
            );
        }

        // save loan in state
        loans[loanId] = Loan({
            borrower: borrower,
            borrowAmount: borrowAmount,
            collateralAmount: collateralAmount,
            creditMultiplierOpen: creditMultiplier,
            caller: address(0),
            callTime: 0,
            originationTime: block.timestamp,
            closeTime: 0,
            debtWhenSeized: 0,
            bidTime: 0
        });
        issuance = _postBorrowIssuance;
        if (maxDelayBetweenPartialRepay != 0) {
            lastPartialRepay[loanId] = block.timestamp;
        }

        // mint debt to the borrower
        RateLimitedCreditMinter(creditMinter).mint(borrower, borrowAmount);

        // pull opening fee from the borrower, if any
        if (openingFee != 0) {
            uint256 _openingFee = (borrowAmount * openingFee) / 1e18;
            // transfer from borrower to ProfitManager & report profit
            CreditToken(creditToken).transferFrom(
                borrower,
                profitManager,
                _openingFee
            );
            ProfitManager(profitManager).notifyPnL(
                address(this),
                int256(_openingFee)
            );
        }

        // pull the collateral from the borrower
        IERC20(collateralToken).safeTransferFrom(
            borrower,
            address(this),
            collateralAmount
        );

        // emit event
        emit LoanBorrow(
            block.timestamp,
            loanId,
            borrower,
            collateralAmount,
            borrowAmount
        );
    }

    /// @notice initiate a new loan
    function borrow(
        uint256 borrowAmount,
        uint256 collateralAmount
    ) external whenNotPaused returns (bytes32 loanId) {
        loanId = _borrow(msg.sender, borrowAmount, collateralAmount);
    }

    /// @notice borrow with a permit on collateral token
    function borrowWithPermit(
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint256 deadline,
        Signature calldata sig
    ) external whenNotPaused returns (bytes32 loanId) {
        IERC20Permit(collateralToken).permit(
            msg.sender,
            address(this),
            collateralAmount,
            deadline,
            sig.v,
            sig.r,
            sig.s
        );
        return _borrow(msg.sender, borrowAmount, collateralAmount);
    }

    /// @notice borrow with a permit on credit token
    function borrowWithCreditPermit(
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint256 deadline,
        Signature calldata sig
    ) external whenNotPaused returns (bytes32 loanId) {
        IERC20Permit(creditToken).permit(
            msg.sender,
            address(this),
            (borrowAmount * openingFee) / 1e18,
            deadline,
            sig.v,
            sig.r,
            sig.s
        );
        return _borrow(msg.sender, borrowAmount, collateralAmount);
    }

    /// @notice borrow with a permit on collateral token + credit token
    function borrowWithPermits(
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint256 deadline,
        Signature calldata collateralPermitSig,
        Signature calldata creditPermitSig
    ) external whenNotPaused returns (bytes32 loanId) {
        IERC20Permit(creditToken).permit(
            msg.sender,
            address(this),
            (borrowAmount * openingFee) / 1e18,
            deadline,
            creditPermitSig.v,
            creditPermitSig.r,
            creditPermitSig.s
        );

        IERC20Permit(collateralToken).permit(
            msg.sender,
            address(this),
            collateralAmount,
            deadline,
            collateralPermitSig.v,
            collateralPermitSig.r,
            collateralPermitSig.s
        );

        return _borrow(msg.sender, borrowAmount, collateralAmount);
    }

    /// @notice add collateral on an open loan.
    /// a borrower might want to add collateral so that his position cannot be called for free.
    /// if the loan is called & goes into liquidation, and less than `ltvBuffer` percent of his
    /// collateral is left after debt repayment, the call fee is reimbursed to the caller.
    function _addCollateral(
        address borrower,
        bytes32 loanId,
        uint256 collateralToAdd
    ) internal {
        require(collateralToAdd != 0, "LendingTerm: cannot add 0");

        Loan storage loan = loans[loanId];

        // check the loan is open
        require(loan.originationTime != 0, "LendingTerm: loan not found");
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // update loan in state
        loans[loanId].collateralAmount += collateralToAdd;

        // pull the collateral from the borrower
        IERC20(collateralToken).safeTransferFrom(
            borrower,
            address(this),
            collateralToAdd
        );

        // emit event
        emit LoanAddCollateral(
            block.timestamp,
            loanId,
            borrower,
            collateralToAdd
        );
    }

    /// @notice add collateral on an open loan.
    function addCollateral(bytes32 loanId, uint256 collateralToAdd) external {
        _addCollateral(msg.sender, loanId, collateralToAdd);
    }

    /// @notice add collateral on an open loan with a permit on collateral token
    function addCollateralWithPermit(
        bytes32 loanId,
        uint256 collateralToAdd,
        uint256 deadline,
        Signature calldata sig
    ) external {
        IERC20Permit(collateralToken).permit(
            msg.sender,
            address(this),
            collateralToAdd,
            deadline,
            sig.v,
            sig.r,
            sig.s
        );

        _addCollateral(msg.sender, loanId, collateralToAdd);
    }

    /// @notice partially repay an open loan.
    /// a borrower might want to partially repay debt so that his position cannot be called for free.
    /// if the loan is called & goes into liquidation, and less than `ltvBuffer` percent of his
    /// collateral is left after debt repayment, the call fee is reimbursed to the caller.
    /// some lending terms might also impose periodic partial repayments.
    function _partialRepay(
        address repayer,
        bytes32 loanId,
        uint256 debtToRepay
    ) internal {
        Loan storage loan = loans[loanId];

        // check the loan is open
        uint256 originationTime = loan.originationTime;
        require(originationTime != 0, "LendingTerm: loan not found");
        require(
            originationTime < block.timestamp,
            "LendingTerm: loan opened in same block"
        );
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // compute partial repayment
        uint256 loanDebt = getLoanDebt(loanId);
        require(debtToRepay < loanDebt, "LendingTerm: full repayment");
        uint256 percentRepaid = (debtToRepay * 1e18) / loanDebt; // [0, 1e18[
        uint256 principalRepaid = (loan.borrowAmount * percentRepaid) / 1e18;
        uint256 interestRepaid = debtToRepay - principalRepaid;
        require(
            principalRepaid != 0 && interestRepaid != 0,
            "LendingTerm: repay too small"
        );
        require(
            debtToRepay >= (loanDebt * minPartialRepayPercent) / 1e18,
            "LendingTerm: repay below min"
        );

        // update loan in state
        loans[loanId].borrowAmount -= principalRepaid;
        lastPartialRepay[loanId] = block.timestamp;

        // pull the debt from the borrower
        CreditToken(creditToken).transferFrom(
            repayer,
            address(this),
            debtToRepay
        );

        // forward profit portion to the ProfitManager, burn the rest
        CreditToken(creditToken).transfer(profitManager, interestRepaid);
        ProfitManager(profitManager).notifyPnL(
            address(this),
            int256(interestRepaid)
        );
        CreditToken(creditToken).burn(principalRepaid);
        RateLimitedCreditMinter(creditMinter).replenishBuffer(principalRepaid);

        // emit event
        emit LoanPartialRepay(block.timestamp, loanId, repayer, debtToRepay);
    }

    /// @notice partially repay an open loan.
    function partialRepay(bytes32 loanId, uint256 debtToRepay) external {
        _partialRepay(msg.sender, loanId, debtToRepay);
    }

    /// @notice partially repay an open loan with a permit on CREDIT token
    function partialRepayWithPermit(
        bytes32 loanId,
        uint256 debtToRepay,
        uint256 deadline,
        Signature calldata sig
    ) external {
        IERC20Permit(creditToken).permit(
            msg.sender,
            address(this),
            debtToRepay,
            deadline,
            sig.v,
            sig.r,
            sig.s
        );

        _partialRepay(msg.sender, loanId, debtToRepay);
    }

    /// @notice repay an open loan
    function _repay(address repayer, bytes32 loanId) internal {
        Loan storage loan = loans[loanId];

        // check the loan is open
        uint256 originationTime = loan.originationTime;
        require(originationTime != 0, "LendingTerm: loan not found");
        require(
            originationTime < block.timestamp,
            "LendingTerm: loan opened in same block"
        );
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // compute interest owed
        uint256 loanDebt = getLoanDebt(loanId);
        uint256 borrowAmount = loan.borrowAmount;
        uint256 interest = loanDebt - borrowAmount;

        /// pull debt from the borrower and replenish the buffer of available debt that can be minted.
        /// @dev `debtToPullForRepay` could be smaller than `loanDebt` if the loan has been called, in this
        /// case the caller already transferred some debt tokens to the lending term, and a reduced
        /// amount has to be pulled from the borrower.
        uint256 callTime = loan.callTime;
        CreditToken(creditToken).transferFrom(
            repayer,
            address(this),
            (callTime != 0 && block.timestamp <= callTime + callPeriod)
                ? (loanDebt - getLoanCallFee(loanId))
                : loanDebt
        );
        if (interest != 0) {
            // forward profit portion to the ProfitManager, burn the rest
            CreditToken(creditToken).transfer(profitManager, interest);
            CreditToken(creditToken).burn(borrowAmount); // == loan.borrowAmount
            RateLimitedCreditMinter(creditMinter).replenishBuffer(borrowAmount);

            // report profit
            ProfitManager(profitManager).notifyPnL(
                address(this),
                int256(interest)
            );
        }

        // close the loan
        loan.closeTime = block.timestamp;
        issuance -= borrowAmount;

        // return the collateral to the borrower
        IERC20(collateralToken).safeTransfer(
            loan.borrower,
            loan.collateralAmount
        );

        // emit event
        emit LoanClose(block.timestamp, loanId, 0, callTime != 0);
    }

    /// @notice repay an open loan
    function repay(bytes32 loanId) external {
        _repay(msg.sender, loanId);
    }

    /// @notice repay an open loan with a permit on CREDIT token
    function repayWithPermit(
        bytes32 loanId,
        uint256 maxDebt,
        uint256 deadline,
        Signature calldata sig
    ) external {
        IERC20Permit(creditToken).permit(
            msg.sender,
            address(this),
            maxDebt,
            deadline,
            sig.v,
            sig.r,
            sig.s
        );

        _repay(msg.sender, loanId);
    }

    /// @notice call a loan in state, and return the amount of debt tokens to pull for call fee.
    function _call(
        bytes32 loanId,
        address caller
    ) internal returns (uint256 debtToPull) {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        uint256 _originationTime = loan.originationTime;
        require(_originationTime != 0, "LendingTerm: loan not found");

        // check that the loan has not been created in the same block
        require(
            _originationTime < block.timestamp,
            "LendingTerm: loan opened in same block"
        );

        // check that the loan is not already called
        require(loan.callTime == 0, "LendingTerm: loan called");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // calculate the call fee
        debtToPull = (loan.borrowAmount * callFee) / 1e18;

        // set the call info
        loan.caller = caller;
        loan.callTime = block.timestamp;

        // emit event
        emit LoanCall(block.timestamp, loanId);
    }

    /// @notice call a single loan.
    /// Borrower has `callPeriod` seconds to repay the loan, or their collateral will be seized.
    function call(bytes32 loanId) external {
        uint256 callFeeAmount = _call(loanId, msg.sender);
        if (callFeeAmount != 0) {
            CreditToken(creditToken).transferFrom(
                msg.sender,
                address(this),
                callFeeAmount
            );
        }
    }

    /// @notice call a list of loans
    function callMany(bytes32[] memory loanIds) external {
        uint256 debtToPullForCallFees = 0;
        for (uint256 i = 0; i < loanIds.length; i++) {
            debtToPullForCallFees += _call(loanIds[i], msg.sender);
        }

        // pull the call fees from caller
        if (debtToPullForCallFees != 0) {
            CreditToken(creditToken).transferFrom(
                msg.sender,
                address(this),
                debtToPullForCallFees
            );
        }
    }

    /// @notice call with a permit on CREDIT token to pull call fees
    function callManyWithPermit(
        bytes32[] memory loanIds,
        uint256 deadline,
        Signature calldata sig
    ) external {
        uint256 debtToPullForCallFees = 0;
        for (uint256 i = 0; i < loanIds.length; i++) {
            debtToPullForCallFees += _call(loanIds[i], msg.sender);
        }

        // pull the call fees from caller
        if (debtToPullForCallFees != 0) {
            IERC20Permit(creditToken).permit(
                msg.sender,
                address(this),
                debtToPullForCallFees,
                deadline,
                sig.v,
                sig.r,
                sig.s
            );
            CreditToken(creditToken).transferFrom(
                msg.sender,
                address(this),
                debtToPullForCallFees
            );
        }
    }

    /// @notice seize the collateral of a loan, to repay outstanding debt.
    /// Under normal conditions, the loans should be call()'d first, to give the borrower an opportunity to repay (the 'call period').
    /// Calling of loans can be skipped if the `hardCap` is zero (bad debt created in the past) or if a loan missed a periodic partialRepay.
    function _seize(bytes32 loanId, address _auctionHouse) internal {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        require(loan.originationTime != 0, "LendingTerm: loan not found");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // set the call info, if not set
        uint256 _callTime = loan.callTime;
        bool loanCalled = _callTime != 0;
        bool canSkipCall = hardCap == 0 || partialRepayDelayPassed(loanId);
        if (loanCalled) {
            // check that the call period has elapsed
            if (!canSkipCall) {
                require(
                    block.timestamp >= loan.callTime + callPeriod,
                    "LendingTerm: call period in progress"
                );
            }
        } else {
            require(canSkipCall, "LendingTerm: loan not called");
            loan.caller = address(this);
            loan.callTime = block.timestamp;
        }

        // close the loan
        uint256 loanDebt = getLoanDebt(loanId);
        loans[loanId].closeTime = block.timestamp;
        loans[loanId].debtWhenSeized = loanDebt;

        // auction the loan collateral
        AuctionHouse(_auctionHouse).startAuction(loanId, loanDebt, loanCalled);

        // emit event
        emit LoanClose(block.timestamp, loanId, 1, loanCalled);
    }

    /// @notice seize the collateral of a single loan
    function seize(bytes32 loanId) external {
        _seize(loanId, auctionHouse);
    }

    /// @notice seize the collateral of a list of loans
    function seizeMany(bytes32[] memory loanIds) public {
        address _auctionHouse = auctionHouse;
        for (uint256 i = 0; i < loanIds.length; i++) {
            _seize(loanIds[i], _auctionHouse);
        }
    }

    /// @notice forgive a loan, marking its debt as a total loss to the system.
    /// The loan is closed (borrower keeps the CREDIT), and the collateral stays on the LendingTerm.
    /// Governance can later unstuck the collateral through `emergencyAction`.
    /// This function is made for emergencies where collateral is frozen or other reverting
    /// conditions on collateral transfers that prevent regular repay() or seize() loan closing.
    function forgive(bytes32 loanId) external onlyCoreRole(CoreRoles.GOVERNOR) {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        require(loan.originationTime != 0, "LendingTerm: loan not found");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // if loan has been called, reimburse the caller
        bool loanCalled = loan.callTime != 0;
        if (loanCalled) {
            CreditToken(creditToken).transfer(
                loan.caller,
                getLoanCallFee(loanId)
            );
        }

        // close the loan
        loans[loanId].closeTime = block.timestamp;
        issuance -= loan.borrowAmount;

        // mark loan as a total loss
        int256 pnl = -int256(loan.borrowAmount);
        ProfitManager(profitManager).notifyPnL(address(this), pnl);

        // set hardcap to 0 to prevent new borrows
        hardCap = 0;

        // emit event
        emit LoanClose(block.timestamp, loanId, 2, loanCalled);
    }

    /// @notice callback from the auctionHouse when au auction concludes
    function onBid(
        bytes32 loanId,
        address bidder,
        AuctionHouse.AuctionResult memory result
    ) external {
        // preliminary checks
        require(msg.sender == auctionHouse, "LendingTerm: invalid caller");
        uint256 _debtWhenSeized = loans[loanId].debtWhenSeized;
        require(_debtWhenSeized != 0, "LendingTerm: loan not seized");
        require(
            loans[loanId].bidTime == 0,
            "LendingTerm: loan auction concluded"
        );

        // sanity checks
        // these should never fail for a properly implemented AuctionHouse contract
        // collateral movements (collateralOut == 0 if forgive())
        uint256 collateralOut = result.collateralToBorrower +
            result.collateralToCaller +
            result.collateralToBidder;
        require(
            collateralOut == loans[loanId].collateralAmount ||
                collateralOut == 0,
            "LendingTerm: invalid collateral movements"
        );
        // credit movements
        uint256 _borrowAmount = loans[loanId].borrowAmount;
        address _caller = loans[loanId].caller;
        uint256 _callFeeAmount = (_borrowAmount * callFee) / 1e18;
        require(
            (_caller == address(this) && result.creditToCaller == 0) || // force closed
                (_caller != address(this) && result.creditToCaller == 0) || // loan called not in danger zone
                (_caller != address(this) &&
                    result.creditToCaller == _callFeeAmount), // loan called & in danger zone
            "LendingTerm: invalid call fee"
        );
        uint256 creditFromCaller = _caller == address(this)
            ? 0
            : _callFeeAmount;
        uint256 creditIn = result.creditFromBidder + creditFromCaller;
        uint256 creditOut = result.creditToCaller +
            result.creditToBurn +
            result.creditToProfit;
        require(
            creditIn == creditOut,
            "LendingTerm: invalid bid credit movement"
        );
        if (result.pnl > 0) {
            require(
                result.creditToProfit == uint256(result.pnl),
                "LendingTerm: invalid profit reported"
            );
            require(
                result.creditToBurn == _borrowAmount,
                "LendingTerm: invalid principal burn"
            );
        } else {
            require(
                result.creditToProfit == 0,
                "LendingTerm: invalid negative profit"
            );
            require(
                result.creditToBurn == result.creditFromBidder,
                "LendingTerm: invalid negative principal burn"
            );
            require(
                uint256(-result.pnl) == _borrowAmount - result.creditFromBidder,
                "LendingTerm: invalid negative pnl"
            );
        }
        require(
            result.pnl ==
                int256(creditIn) -
                    int256(_borrowAmount) -
                    int256(result.creditToCaller),
            "LendingTerm: invalid pnl"
        );

        // save bid time
        loans[loanId].bidTime = block.timestamp;

        // pull credit from bidder
        if (result.creditFromBidder != 0) {
            CreditToken(creditToken).transferFrom(
                bidder,
                address(this),
                result.creditFromBidder
            );
        }

        // send credit to caller
        if (result.creditToCaller != 0) {
            CreditToken(creditToken).transfer(
                loans[loanId].caller,
                result.creditToCaller
            );
        }

        // burn credit principal
        if (result.creditToBurn != 0) {
            RateLimitedCreditMinter(creditMinter).replenishBuffer(
                result.creditToBurn
            );
            CreditToken(creditToken).burn(result.creditToBurn);
        }

        // handle profit & losses
        if (result.pnl != 0) {
            if (result.pnl > 0) {
                // forward profit to ProfitManager before notifying it of profits
                // the ProfitManager will handle profit distribution.
                CreditToken(creditToken).transfer(
                    profitManager,
                    result.creditToProfit
                );
            } else if (result.pnl < 0) {
                // if auction resulted in bad debt, prevent new loans from being issued and allow
                // force-closing of all loans (seize() without call() first).
                hardCap = 0;
            }
            ProfitManager(profitManager).notifyPnL(address(this), result.pnl);
        }

        // decrease issuance
        issuance -= loans[loanId].borrowAmount;

        // send collateral to borrower
        if (result.collateralToBorrower != 0) {
            IERC20(collateralToken).safeTransfer(
                loans[loanId].borrower,
                result.collateralToBorrower
            );
        }

        // send collateral to caller
        if (result.collateralToCaller != 0) {
            IERC20(collateralToken).safeTransfer(
                loans[loanId].caller,
                result.collateralToCaller
            );
        }

        // send collateral to bidder
        if (result.collateralToBidder != 0) {
            IERC20(collateralToken).safeTransfer(
                bidder,
                result.collateralToBidder
            );
        }

        emit LoanBid(
            block.timestamp,
            loanId,
            result.collateralToBidder,
            result.creditFromBidder
        );
    }

    /// @notice set the address of the auction house.
    /// governor-only, to allow full governance to update the auction mechanisms.
    function setAuctionHouse(
        address _newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        // allow configuration changes only when there are no auctions in progress.
        // updating the auction house while auctions are in progress could break the loan
        // lifecycle, as it would prevent the former auctionHouse (that have active auctions)
        // from reporting the result to the lending term.
        require(
            AuctionHouse(auctionHouse).nAuctionsInProgress() == 0,
            "LendingTerm: auctions in progress"
        );

        auctionHouse = _newValue;
    }

    /// @notice set the hardcap of CREDIT mintable in this term.
    /// allows to update a term's arbitrary hardcap without doing a gauge & loans migration.
    function setHardCap(
        uint256 _newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        hardCap = _newValue;
    }
}
