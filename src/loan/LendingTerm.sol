// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

/// @notice Lending Term contract of the Ethereum Credit Guild, a base implementation of
/// smart contract issuing CREDIT debt and escrowing collateral assets.
contract LendingTerm is EIP712, CoreRef {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    mapping(address => Counters.Counter) private _nonces;

    // events for the lifecycle of loans that happen in the lending term
    /// @notice emitted when new loans are opened (mint debt to borrower, pull collateral from borrower).
    event LoanBorrow(uint256 indexed when, bytes32 indexed loanId, address indexed borrower, uint256 collateralAmount, uint256 borrowAmount);
    /// @notice emitted when a loan is called (repayer has `callPeriod` seconds to repay at a discount).
    event LoanCall(uint256 indexed when, bytes32 indexed loanId);
    /// @notice emitted when a loan is closed (repay, seize, forgive).
    /// the lifecycle of the loan might continue in the AuctionHouse, but when this event is emitted, the
    /// responsibility of the LendingTerm is over.
    /// closeType enum : 0 = repay, 1 = seize, 2 = forgive.
    event LoanClose(uint256 indexed when, bytes32 indexed loanId, uint8 indexed closeType, bool loanCalled);
    /// @notice emitted when someone adds collateral to a loan
    event LoanAddCollateral(uint256 indexed when, bytes32 indexed loanId, address indexed borrower, uint256 collateralAmount);
    /// @notice emitted when someone partially repays a loan
    event LoanPartialRepay(uint256 indexed when, bytes32 indexed loanId, address indexed repayer, uint256 repayAmount);

    // signed messages for the lifecycle of loans
    bytes32 public constant _BORROW_TYPEHASH = keccak256("Borrow(address term,address borrower,uint256 borrowAmount,uint256 collateralAmount,uint256 nonce,uint256 deadline)");
    bytes32 public constant _REPAY_TYPEHASH = keccak256("Repay(address term,address repayer,bytes32 loanId,uint256 nonce,uint256 deadline)");
    bytes32 public constant _CALL_TYPEHASH = keccak256("Call(address term,address caller,bytes32[] loanIds,uint256 nonce,uint256 deadline)");

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
    mapping(bytes32=>uint256) public lastPartialRepay;

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

    /// @notice current number of CREDIT issued in active loans on this term
    uint256 public issuance;

    struct LendingTermParams {
        address collateralToken;
        uint256 maxDebtPerCollateralToken;
        uint256 interestRate;
        uint256 maxDelayBetweenPartialRepay;
        uint256 minPartialRepayPercent;
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
    ) EIP712("Ethereum Credit Guild", "1") CoreRef(_core) {
        guildToken = _guildToken;
        auctionHouse = _auctionHouse;
        creditMinter = _creditMinter;
        creditToken = _creditToken;
        collateralToken = params.collateralToken;
        maxDebtPerCollateralToken = params.maxDebtPerCollateralToken;
        interestRate = params.interestRate;
        maxDelayBetweenPartialRepay = params.maxDelayBetweenPartialRepay;
        minPartialRepayPercent = params.minPartialRepayPercent;
        callFee = params.callFee;
        callPeriod = params.callPeriod;
        hardCap = params.hardCap;
        ltvBuffer = params.ltvBuffer;
    }

    function nonces(address user) external view returns (uint256) {
        return _nonces[user].current();
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _useNonce(address user) internal returns (uint256 current) {
        Counters.Counter storage nonce = _nonces[user];
        current = nonce.current();
        nonce.increment();
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

    /// @notice returns true if the term has a maximum delay between partial repays
    /// and the loan has passed the delay for partial repayments.
    function partialRepayDelayPassed(bytes32 loanId) public view returns (bool) {
        // if no periodic partial repays are expected, always return false
        if (maxDelayBetweenPartialRepay == 0) return false;

        // if loan doesn't exist, return false
        if (loans[loanId].originationTime == 0) return false;

        // if loan is closed, return false
        if (loans[loanId].closeTime != 0) return false;
        
        // return true if delay is passed
        return lastPartialRepay[loanId] < block.timestamp - maxDelayBetweenPartialRepay;
    }

    /// @notice initiate a new loan
    function _borrow(
        address borrower,
        uint256 borrowAmount,
        uint256 collateralAmount
    ) internal returns (bytes32 loanId) {
        require(borrowAmount != 0, "LendingTerm: cannot borrow 0");
        require(collateralAmount != 0, "LendingTerm: cannot stake 0");

        loanId = keccak256(abi.encode(borrower, address(this), block.timestamp));

        // check that the loan doesn't already exist
        require(loans[loanId].originationTime == 0, "LendingTerm: loan exists");

        // check that enough CREDIT is borrowed
        require(borrowAmount >= MIN_BORROW, "LendingTerm: borrow amount too low");

        // check that enough collateral is provided
        uint256 maxBorrow = collateralAmount * maxDebtPerCollateralToken / 1e18;
        require(borrowAmount <= maxBorrow, "LendingTerm: not enough collateral");

        // check that ltvBuffer is respected
        uint256 maxBorrowLtv = maxBorrow * 1e18 / (1e18 + ltvBuffer);
        require(borrowAmount <= maxBorrowLtv, "LendingTerm: not enough LTV buffer");

        // check the hardcap
        uint256 _issuance = issuance;
        uint256 _postBorrowIssuance = _issuance + borrowAmount;
        require(_postBorrowIssuance <= hardCap, "LendingTerm: hardcap reached");

        // check the debt ceiling
        uint256 _totalSupply = IERC20(creditToken).totalSupply();
        uint256 debtCeiling = GuildToken(guildToken).calculateGaugeAllocation(address(this), _totalSupply + borrowAmount) * GAUGE_CAP_TOLERANCE / 1e18;
        if (_totalSupply == 0) {
            // if the lending term is deprecated, `calculateGaugeAllocation` will return 0, and the borrow
            // should revert because the debt ceiling is reached (no borrows should be allowed anymore).
            // first borrow in the system does not check proportions of issuance, just that the term is not deprecated.
            require(debtCeiling != 0, "LendingTerm: debt ceiling reached");
        } else {
            require(_postBorrowIssuance <= debtCeiling, "LendingTerm: debt ceiling reached");
        }

        // save loan in state
        loans[loanId] = Loan({
            borrower: borrower,
            borrowAmount: borrowAmount,
            collateralAmount: collateralAmount,
            caller: address(0),
            callTime: 0,
            originationTime: block.timestamp,
            closeTime: 0
        });
        issuance = _postBorrowIssuance;
        if (maxDelayBetweenPartialRepay != 0) {
            lastPartialRepay[loanId] = block.timestamp;
        }

        // mint debt to the borrower
        RateLimitedCreditMinter(creditMinter).mint(borrower, borrowAmount);

        // pull the collateral from the borrower
        IERC20(collateralToken).safeTransferFrom(borrower, address(this), collateralAmount);

        // emit event
        emit LoanBorrow(block.timestamp, loanId, borrower, collateralAmount, borrowAmount);
    }

    /// @notice initiate a new loan
    function borrow(
        uint256 borrowAmount,
        uint256 collateralAmount
    ) external whenNotPaused returns (bytes32 loanId) {
        loanId = _borrow(msg.sender, borrowAmount, collateralAmount);
    }

    /// @notice borrow with a signature to open the loan
    function borrowBySig(
        address borrower,
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint256 deadline,
        Signature calldata sig
    ) external whenNotPaused returns (bytes32 loanId) {
        require(block.timestamp <= deadline, "LendingTerm: expired deadline");

        bytes32 structHash = keccak256(abi.encode(_BORROW_TYPEHASH, address(this), borrower, borrowAmount, collateralAmount, _useNonce(borrower), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, sig.v, sig.r, sig.s);
        require(signer == borrower, "LendingTerm: invalid signature");

        return _borrow(borrower, borrowAmount, collateralAmount);
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

    /// @notice borrow with a signature to open the loan and a permit on collateral token
    function borrowBySigWithPermit(
        address borrower,
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint256 deadline,
        Signature calldata borrowSig,
        Signature calldata permitSig
    ) external whenNotPaused returns (bytes32 loanId) {
        require(block.timestamp <= deadline, "LendingTerm: expired deadline");

        bytes32 structHash = keccak256(abi.encode(_BORROW_TYPEHASH, address(this), borrower, borrowAmount, collateralAmount, _useNonce(borrower), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, borrowSig.v, borrowSig.r, borrowSig.s);
        require(signer == borrower, "LendingTerm: invalid signature");

        IERC20Permit(collateralToken).permit(
            borrower,
            address(this),
            collateralAmount,
            deadline,
            permitSig.v,
            permitSig.r,
            permitSig.s
        );

        return _borrow(borrower, borrowAmount, collateralAmount);
    }

    /// @notice add collateral on an open loan.
    /// a borrower might want to add collateral so that his position cannot be called for free.
    /// if the loan is called & goes into liquidation, and less than `ltvBuffer` percent of his
    /// collateral is left after debt repayment, the call fee is reimbursed to the caller.
    function _addCollateral(address borrower, bytes32 loanId, uint256 collateralToAdd) internal {
        require(collateralToAdd != 0, "LendingTerm: cannot add 0");

        Loan storage loan = loans[loanId];

        // check the loan is open
        require(loan.originationTime != 0, "LendingTerm: loan not found");
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // update loan in state
        loans[loanId].collateralAmount += collateralToAdd;

        // pull the collateral from the borrower
        IERC20(collateralToken).safeTransferFrom(borrower, address(this), collateralToAdd);

        // emit event
        emit LoanAddCollateral(block.timestamp, loanId, borrower, collateralToAdd);
    }

    /// @notice add collateral on an open loan.
    function addCollateral(bytes32 loanId, uint256 collateralToAdd) external {
        _addCollateral(msg.sender, loanId, collateralToAdd);
    }

    /// @notice partially repay an open loan.
    /// a borrower might want to partially repay debt so that his position cannot be called for free.
    /// if the loan is called & goes into liquidation, and less than `ltvBuffer` percent of his
    /// collateral is left after debt repayment, the call fee is reimbursed to the caller.
    /// some lending terms might also impose periodic partial repayments.
    function _partialRepay(address repayer, bytes32 loanId, uint256 debtToRepay) internal {
        Loan storage loan = loans[loanId];

        // check the loan is open
        uint256 originationTime = loan.originationTime;
        require(originationTime != 0, "LendingTerm: loan not found");
        require(originationTime < block.timestamp, "LendingTerm: loan opened in same block");
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // compute partial repayment
        uint256 loanDebt = getLoanDebt(loanId);
        require(debtToRepay < loanDebt, "LendingTerm: full repayment");
        uint256 percentRepaid = debtToRepay * 1e18 / loanDebt; // [0, 1e18[
        uint256 principalRepaid = loan.borrowAmount * percentRepaid / 1e18;
        uint256 interestRepaid = debtToRepay- principalRepaid;
        require(principalRepaid != 0 && interestRepaid != 0, "LendingTerm: repay too small");
        require(debtToRepay >= loanDebt * minPartialRepayPercent / 1e18, "LendingTerm: repay below min");

        // update loan in state
        loans[loanId].borrowAmount -= principalRepaid;
        lastPartialRepay[loanId] = block.timestamp;

        // pull the debt from the borrower
        address _creditToken = creditToken;
        address _guildToken = guildToken;
        IERC20(_creditToken).safeTransferFrom(repayer, address(this), debtToRepay);

        // forward profit portion to the GUILD token, burn the rest
        IERC20(_creditToken).transfer(_guildToken, interestRepaid);
        GuildToken(_guildToken).notifyPnL(address(this), int256(interestRepaid));
        CreditToken(_creditToken).burn(principalRepaid);
        RateLimitedCreditMinter(creditMinter).replenishBuffer(principalRepaid);

        // emit event
        emit LoanPartialRepay(block.timestamp, loanId, repayer, debtToRepay);
    }

    /// @notice partially repay an open loan.
    function partialRepay(bytes32 loanId, uint256 debtToRepay) external {
        _partialRepay(msg.sender, loanId, debtToRepay);
    }

    /// @notice repay an open loan
    function _repay(address repayer, bytes32 loanId) internal {
        Loan storage loan = loans[loanId];

        // check the loan is open
        uint256 originationTime = loan.originationTime;
        require(originationTime != 0, "LendingTerm: loan not found");
        require(originationTime < block.timestamp, "LendingTerm: loan opened in same block");
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // compute interest owed
        uint256 loanDebt = getLoanDebt(loanId);
        uint256 borrowAmount = loan.borrowAmount;
        uint256 interest = loanDebt - borrowAmount;

        /// pull debt from the borrower and replenish the buffer of available debt that can be minted.
        /// @dev `debtToPullForRepay` could be smaller than `loanDebt` if the loan has been called, in this
        /// case the caller already transferred some debt tokens to the lending term, and a reduced
        /// amount has to be pulled from the borrower.
        address _creditToken = creditToken;
        uint256 callTime = loan.callTime;
        IERC20(_creditToken).transferFrom(
            repayer,
            address(this),
            (callTime != 0 && block.timestamp <= callTime + callPeriod) ? (loanDebt - getLoanCallFee(loanId)) : loanDebt
        );
        if (interest != 0) {
            // forward profit portion to the GUILD token, burn the rest
            IERC20(_creditToken).transfer(guildToken, interest);
            CreditToken(_creditToken).burn(borrowAmount); // == loan.borrowAmount
            RateLimitedCreditMinter(creditMinter).replenishBuffer(borrowAmount);

            // report profit
            GuildToken(guildToken).notifyPnL(address(this), int256(interest));
        }

        // close the loan
        loan.closeTime = block.timestamp;
        issuance -= borrowAmount;

        // return the collateral to the borrower
        IERC20(collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        // emit event
        emit LoanClose(block.timestamp, loanId, 0, callTime != 0);
    }

    /// @notice repay an open loan
    function repay(bytes32 loanId) external {
        _repay(msg.sender, loanId);
    }

    /// @notice repay an open loan by signature
    function repayBySig(
        address repayer,
        bytes32 loanId,
        uint256 deadline,
        Signature calldata sig
    ) external {
        require(block.timestamp <= deadline, "LendingTerm: expired deadline");

        bytes32 structHash = keccak256(abi.encode(_REPAY_TYPEHASH, address(this), repayer, loanId, _useNonce(repayer), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, sig.v, sig.r, sig.s);
        require(signer == repayer, "LendingTerm: invalid signature");

        _repay(repayer, loanId);
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

    /// @notice repay an open loan by signature and with a permit on CREDIT token
    function repayBySigWithPermit(
        address repayer,
        bytes32 loanId,
        uint256 maxDebt,
        uint256 deadline,
        Signature calldata repaySig,
        Signature calldata permitSig
    ) external {
        require(block.timestamp <= deadline, "LendingTerm: expired deadline");

        bytes32 structHash = keccak256(abi.encode(_REPAY_TYPEHASH, address(this), repayer, loanId, _useNonce(repayer), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, repaySig.v, repaySig.r, repaySig.s);
        require(signer == repayer, "LendingTerm: invalid signature");

        IERC20Permit(creditToken).permit(
            repayer,
            address(this),
            maxDebt,
            deadline,
            permitSig.v,
            permitSig.r,
            permitSig.s
        );
        
        _repay(repayer, loanId);
    }

    /// @notice call a loan in state, and return the amount of debt tokens to pull for call fee.
    function _call(bytes32 loanId, address caller) internal returns (uint256 debtToPull) {
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
        debtToPull = loan.borrowAmount * callFee / 1e18;
    
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
            IERC20(creditToken).transferFrom(msg.sender, address(this), callFeeAmount);
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
            IERC20(creditToken).transferFrom(msg.sender, address(this), debtToPullForCallFees);
        }
    }

    /// @notice call a list of loans using a signed Call message
    function callManyBySig(
        address caller,
        bytes32[] memory loanIds,
        uint256 deadline,
        Signature calldata sig
    ) external {
        require(block.timestamp <= deadline, "LendingTerm: expired deadline");

        bytes32 structHash = keccak256(abi.encode(_CALL_TYPEHASH, address(this), caller, keccak256(abi.encodePacked(loanIds)), _useNonce(caller), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, sig.v, sig.r, sig.s);
        require(signer == caller, "LendingTerm: invalid signature");

        uint256 debtToPullForCallFees = 0;
        for (uint256 i = 0; i < loanIds.length; i++) {
            debtToPullForCallFees += _call(loanIds[i], caller);
        }

        // pull the call fees from caller
        if (debtToPullForCallFees != 0) {
            IERC20(creditToken).transferFrom(caller, address(this), debtToPullForCallFees);
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
            IERC20(creditToken).transferFrom(msg.sender, address(this), debtToPullForCallFees);
        }
    }

    /// @notice call by signature with a permit on CREDIT token to pull call fees
    function callManyBySigWithPermit(
        address caller,
        bytes32[] memory loanIds,
        uint256 deadline,
        Signature calldata callSig,
        Signature calldata permitSig
    ) external {
        require(block.timestamp <= deadline, "LendingTerm: expired deadline");

        bytes32 structHash = keccak256(abi.encode(_CALL_TYPEHASH, address(this), caller, keccak256(abi.encodePacked(loanIds)), _useNonce(caller), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, callSig.v, callSig.r, callSig.s);
        require(signer == caller, "LendingTerm: invalid signature");

        uint256 debtToPullForCallFees = 0;
        for (uint256 i = 0; i < loanIds.length; i++) {
            debtToPullForCallFees += _call(loanIds[i], caller);
        }

        // pull the call fees from caller
        if (debtToPullForCallFees != 0) {
            IERC20Permit(creditToken).permit(
                caller,
                address(this),
                debtToPullForCallFees,
                deadline,
                permitSig.v,
                permitSig.r,
                permitSig.s
            );
            IERC20(creditToken).transferFrom(caller, address(this), debtToPullForCallFees);
        }
    }

    /// @notice seize the collateral of a loan, to repay outstanding debt.
    /// Under normal conditions, the loans should be call()'d first, to give the borrower an opportunity to repay (the 'call period').
    /// Calling of loans can be skipped if the `issuance` is above `hardCap` or if a loan missed a periodic partialRepay.
    function _seize(
        bytes32 loanId,
        address _auctionHouse,
        uint256 issuanceBefore
    ) internal returns (
        uint256 debtToForward,
        uint256 issuanceDecrease
    ) {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        require(loan.originationTime != 0, "LendingTerm: loan not found");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // set the call info, if not set
        uint256 _callTime = loan.callTime;
        bool loanCalled = _callTime != 0;
        bool canSkipCall = issuanceBefore > hardCap || partialRepayDelayPassed(loanId);
        if (loanCalled) {
            // check that the call period has elapsed
            if (!canSkipCall) {
                require(block.timestamp >= loan.callTime + callPeriod, "LendingTerm: call period in progress");
            }
            debtToForward = getLoanCallFee(loanId);
        } else {
            require(canSkipCall, "LendingTerm: loan not called");
            loan.caller = msg.sender;
            loan.callTime = block.timestamp;
        }

        // close the loan
        uint256 loanDebt = getLoanDebt(loanId);
        loans[loanId].closeTime = block.timestamp;
        issuanceDecrease = loan.borrowAmount;

        // auction the loan collateral
        IERC20(collateralToken).safeApprove(_auctionHouse, loan.collateralAmount);
        AuctionHouse(_auctionHouse).startAuction(loanId, loanDebt, loanCalled);

        // emit event
        emit LoanClose(block.timestamp, loanId, 1, loanCalled);
    }

    /// @notice seize a single loan without attempt to skip the call period.
    function seize(bytes32 loanId) external {
        address _auctionHouse = auctionHouse;
        uint256 _issuance = issuance;
        (
            uint256 debtToForward,
            uint256 issuanceDecrease
        ) = _seize(loanId, _auctionHouse, _issuance);

        // send CREDIT from the call fees to the auction house
        if (debtToForward != 0) {
            IERC20(creditToken).transfer(_auctionHouse, debtToForward);
        }

        // update issuance
        issuance = _issuance - issuanceDecrease;
    }

    /// @notice seize the collateral of a list of loans
    function seizeMany(bytes32[] memory loanIds) public {
        address _auctionHouse = auctionHouse;
        uint256 newIssuance = issuance;
        uint256 totalDebtToForward;
        for (uint256 i = 0; i < loanIds.length; i++) {
            (
                uint256 debtToForward,
                uint256 issuanceDecrease
            ) = _seize(loanIds[i], _auctionHouse, newIssuance);

            newIssuance -= issuanceDecrease;
            totalDebtToForward += debtToForward;
        }

        // send CREDIT from the call fees to the auction house
        if (totalDebtToForward != 0) {
            IERC20(creditToken).transfer(_auctionHouse, totalDebtToForward);
        }

        // update issuance
        issuance = newIssuance;
    }

    /// @notice forgive a loan, marking its debt as a total loss to the system.
    /// The loan is closed (borrower keeps the CREDIT), and the collateral stays on the LendingTerm.
    /// Governance can later unstuck the collateral through `emergencyAction`.
    /// This function is made for emergencies where collateral is frozen or other reverting
    /// conditions on collateral transfers that prevent it from being sent to the auctionHouse
    /// for a regular repay() or seize() loan closing.
    function forgive(bytes32 loanId) external onlyCoreRole(CoreRoles.GOVERNOR) {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        require(loan.originationTime != 0, "LendingTerm: loan not found");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // if loan has been called, reimburse the caller
        bool loanCalled = loan.callTime != 0;
        if (loanCalled) {
            IERC20(creditToken).transfer(loan.caller, getLoanCallFee(loanId));
        }

        // close the loan
        loans[loanId].closeTime = block.timestamp;
        issuance -= loan.borrowAmount;

        // mark loan as a total loss
        int256 pnl = -int256(loan.borrowAmount);
        GuildToken(guildToken).notifyPnL(address(this), pnl);

        // set hardcap to 0 to prevent new borrows
        hardCap = 0;

        // emit event
        emit LoanClose(block.timestamp, loanId, 2, loanCalled);
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
