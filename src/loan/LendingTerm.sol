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
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

/// @notice Lending Term contract of the Ethereum Credit Guild, a base implementation of
/// smart contract issuing CREDIT debt and escrowing collateral assets.
/// Note that interest rate is non-compounding and the percentage is expressed per
/// period of `YEAR` seconds.
contract LendingTerm is CoreRef {
    using SafeERC20 for IERC20;

    // events for the lifecycle of loans that happen in the lending term
    /// @notice emitted when new loans are opened (mint debt to borrower, pull collateral from borrower).
    event LoanOpen(
        uint256 indexed when,
        bytes32 indexed loanId,
        address indexed borrower,
        uint256 collateralAmount,
        uint256 borrowAmount
    );
    /// @notice emitted when a loan is called.
    event LoanCall(uint256 indexed when, bytes32 indexed loanId);
    /// @notice emitted when a loan is closed (repay, onBid after a call, forgive).
    enum LoanCloseType {
        Repay,
        Call,
        Forgive
    }
    event LoanClose(
        uint256 indexed when,
        bytes32 indexed loanId,
        LoanCloseType indexed closeType,
        uint256 debtRepaid
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

    /// @notice timestamp of last partial repayment for a given loanId.
    /// during borrow(), this is initialized to the borrow timestamp, if
    /// maxDelayBetweenPartialRepay is != 0
    mapping(bytes32 => uint256) public lastPartialRepay;

    struct Loan {
        address borrower; // address of a loan's borrower
        uint256 borrowTime; // the time the loan was initiated
        uint256 borrowAmount; // initial CREDIT debt of a loan
        uint256 borrowCreditMultiplier; // creditMultiplier when loan was opened
        uint256 collateralAmount; // balance of collateral token provided by the borrower
        address caller; // a caller of 0 indicates that the loan has not been called
        uint256 callTime; // a call time of 0 indicates that the loan has not been called
        uint256 callDebt; // the CREDIT debt when the loan was called
        uint256 closeTime; // the time the loan was closed (repaid or call+bid or forgive)
    }

    /// @notice the list of all loans that existed or are still active.
    /// @dev see public getLoan(loanId) getter.
    mapping(bytes32 => Loan) internal loans;

    /// @notice current number of CREDIT issued in active loans on this term
    /// @dev this can be lower than the sum of all loan's CREDIT debts because
    /// interests accrue and some loans might have been opened before the creditMultiplier
    /// was last updated, resulting in higher CREDIT debt than what was originally borrowed.
    uint256 public issuance;

    struct LendingTermReferences {
        /// @notice reference to the ProfitManager
        address profitManager;
        /// @notice reference to the GUILD token
        address guildToken;
        /// @notice reference to the auction house contract used to
        /// sell loan collateral for CREDIT if loans are called.
        address auctionHouse;
        /// @notice reference to the credit minter contract
        address creditMinter;
        /// @notice reference to the CREDIT token
        address creditToken;
    }

    /// @notice References to other protocol contracts (see struct for more details)
    LendingTermReferences internal refs;

    struct LendingTermParams {
        /// @notice reference to the collateral token
        address collateralToken;
        /// @notice max number of debt tokens issued per collateral token.
        /// @dev be mindful of the decimals here, because if collateral
        /// token doesn't have 18 decimals, this variable is used to scale
        /// the decimals.
        /// For example, for USDC collateral, this variable should be around
        /// ~1e30, to allow 1e6 * 1e30 / 1e18 ~= 1e18 CREDIT to be borrowed for
        /// each 1e6 units (1 USDC) of collateral, if CREDIT is targeted to be
        /// worth around 1 USDC.
        uint256 maxDebtPerCollateralToken;
        /// @notice interest rate paid by the borrower, expressed as an APR
        /// with 18 decimals (0.01e18 = 1% APR). The base for 1 year is the YEAR constant.
        uint256 interestRate;
        /// @notice maximum delay, in seconds, between partial debt repayments.
        /// if set to 0, no periodic partial repayments are expected.
        /// if a partial repayment is missed (delay has passed), the loan
        /// can be called.
        uint256 maxDelayBetweenPartialRepay;
        /// @notice minimum percent of the total debt (principal + interests) to
        /// repay during partial debt repayments.
        /// percentage is expressed with 18 decimals, e.g. 0.05e18 = 5% debt.
        uint256 minPartialRepayPercent;
        /// @notice the opening fee is a percent of interest that instantly accrues
        /// when the loan is opened.
        /// The opening fee is expressed as a percentage of the borrowAmount, with 18
        /// decimals, e.g. 0.05e18 = 5% of the borrowed amount.
        /// A loan with 2% openingFee and 3% interestRate will owe 102% of the borrowed
        /// amount just after being open, and after 1 year will owe 105%.
        uint256 openingFee;
        /// @notice the absolute maximum amount of debt this lending term can issue
        /// at any given time, regardless of the gauge allocations.
        uint256 hardCap;
    }

    /// @notice Params of the LendingTerm (see struct for more details)
    LendingTermParams internal params;

    constructor() CoreRef(address(1)) {
        // core is set to address(1) to prevent implementation from being initialized,
        // only proxies on the implementation can be initialized.
    }

    /// @notice initialize storage with references to other protocol contracts
    /// and the lending term parameters for this instance.
    function initialize(
        address _core,
        LendingTermReferences calldata _refs,
        LendingTermParams calldata _params
    ) external {
        // can initialize only once
        assert(address(core()) == address(0));
        assert(_core != address(0));

        // initialize storage
        _setCore(_core);
        refs = _refs;
        params = _params;
    }

    /// @notice get references of this term to other protocol contracts
    function getReferences()
        external
        view
        returns (LendingTermReferences memory)
    {
        return refs;
    }

    /// @notice get parameters of this term
    function getParameters() external view returns (LendingTermParams memory) {
        return params;
    }

    /// @notice get parameter 'collateralToken' of this term
    function collateralToken() external view returns (address) {
        return params.collateralToken;
    }

    /// @notice get a loan
    function getLoan(bytes32 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    /// @notice outstanding borrowed amount of a loan, including interests
    function getLoanDebt(bytes32 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 borrowTime = loan.borrowTime;

        if (borrowTime == 0) {
            return 0;
        }

        if (loan.closeTime != 0) {
            return 0;
        }

        if (loan.callTime != 0) {
            return loan.callDebt;
        }

        // compute interest owed
        uint256 borrowAmount = loan.borrowAmount;
        uint256 interest = (borrowAmount *
            params.interestRate *
            (block.timestamp - borrowTime)) /
            YEAR /
            1e18;
        uint256 loanDebt = borrowAmount + interest;
        uint256 _openingFee = params.openingFee;
        if (_openingFee != 0) {
            loanDebt += (borrowAmount * _openingFee) / 1e18;
        }
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        loanDebt = (loanDebt * loan.borrowCreditMultiplier) / creditMultiplier;

        return loanDebt;
    }

    /// @notice returns true if the term has a maximum delay between partial repays
    /// and the loan has passed the delay for partial repayments.
    function partialRepayDelayPassed(
        bytes32 loanId
    ) public view returns (bool) {
        // if no periodic partial repays are expected, always return false
        if (params.maxDelayBetweenPartialRepay == 0) return false;

        // if loan doesn't exist, return false
        if (loans[loanId].borrowTime == 0) return false;

        // if loan is closed, return false
        if (loans[loanId].closeTime != 0) return false;

        // return true if delay is passed
        return
            lastPartialRepay[loanId] <
            block.timestamp - params.maxDelayBetweenPartialRepay;
    }

    /// @notice returns the maximum amount of debt that can be issued by this term
    /// according to the current gauge allocations.
    /// Note that the debt ceiling can be lower than the current issuance under 4 conditions :
    /// - params.hardCap is lower than since last borrow happened
    /// - gauge votes are fewer than when last borrow happened
    /// - profitManager.totalBorrowedCredit() decreased since last borrow
    /// - creditMinter.buffer() is close to being depleted
    /// @dev this solves the following equation :
    /// borrowAmount + issuance <=
    /// (totalBorrowedCredit + borrowAmount) * gaugeWeight * gaugeWeightTolerance / totalWeight / 1e18
    /// which is the formula to check debt ceiling in the borrow function.
    /// This gives the maximum borrowable amount to achieve 100% utilization of the debt
    /// ceiling, and if we add the current issuance to it, we get the current debt ceiling.
    /// @param gaugeWeightDelta an hypothetical change in gauge weight
    /// @return the maximum amount of debt that can be issued by this term
    function debtCeiling(
        int256 gaugeWeightDelta
    ) public view returns (uint256) {
        address _guildToken = refs.guildToken; // cached SLOAD
        uint256 gaugeWeight = GuildToken(_guildToken).getGaugeWeight(
            address(this)
        );
        gaugeWeight = uint256(int256(gaugeWeight) + gaugeWeightDelta);
        uint256 gaugeType = GuildToken(_guildToken).gaugeType(address(this));
        uint256 totalWeight = GuildToken(_guildToken).totalTypeWeight(
            gaugeType
        );
        uint256 creditMinterBuffer = RateLimitedMinter(refs.creditMinter)
            .buffer();
        uint256 _hardCap = params.hardCap; // cached SLOAD
        if (gaugeWeight == 0) {
            return 0; // no gauge vote, 0 debt ceiling
        } else if (gaugeWeight == totalWeight) {
            // one gauge, unlimited debt ceiling
            // returns min(hardCap, creditMinterBuffer)
            return
                _hardCap < creditMinterBuffer ? _hardCap : creditMinterBuffer;
        }
        uint256 _issuance = issuance; // cached SLOAD
        uint256 totalBorrowedCredit = ProfitManager(refs.profitManager)
            .totalBorrowedCredit();
        uint256 gaugeWeightTolerance = ProfitManager(refs.profitManager)
            .gaugeWeightTolerance();
        if (totalBorrowedCredit == 0 && gaugeWeight != 0) {
            // first-ever CREDIT mint on a non-zero gauge weight term
            // does not check the relative debt ceilings
            // returns min(hardCap, creditMinterBuffer)
            return
                _hardCap < creditMinterBuffer ? _hardCap : creditMinterBuffer;
        }
        uint256 toleratedGaugeWeight = (gaugeWeight * gaugeWeightTolerance) /
            1e18;
        uint256 debtCeilingBefore = (totalBorrowedCredit *
            toleratedGaugeWeight) / totalWeight;
        if (_issuance >= debtCeilingBefore) {
            return debtCeilingBefore; // no more borrows allowed
        }
        uint256 remainingDebtCeiling = debtCeilingBefore - _issuance; // always >0
        if (toleratedGaugeWeight >= totalWeight) {
            // if the gauge weight is above 100% when we include tolerance,
            // the gauge relative debt ceilings are not constraining.
            return
                _hardCap < creditMinterBuffer ? _hardCap : creditMinterBuffer;
        }
        uint256 otherGaugesWeight = totalWeight - toleratedGaugeWeight; // always >0
        uint256 maxBorrow = (remainingDebtCeiling * totalWeight) /
            otherGaugesWeight;
        uint256 _debtCeiling = _issuance + maxBorrow;
        // return min(creditMinterBuffer, hardCap, debtCeiling)
        if (creditMinterBuffer < _debtCeiling) {
            return creditMinterBuffer;
        }
        if (_hardCap < _debtCeiling) {
            return _hardCap;
        }
        return _debtCeiling;
    }

    /// @notice returns the debt ceiling without change to gauge weight
    function debtCeiling() external view returns (uint256) {
        return debtCeiling(0);
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
        require(loans[loanId].borrowTime == 0, "LendingTerm: loan exists");

        // check that enough collateral is provided
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 maxBorrow = (collateralAmount *
            params.maxDebtPerCollateralToken) / creditMultiplier;
        require(
            borrowAmount <= maxBorrow,
            "LendingTerm: not enough collateral"
        );

        // check that enough CREDIT is borrowed
        require(
            borrowAmount >= ProfitManager(refs.profitManager).minBorrow(),
            "LendingTerm: borrow amount too low"
        );

        // check the hardcap
        uint256 _issuance = issuance;
        uint256 _postBorrowIssuance = _issuance + borrowAmount;
        require(
            _postBorrowIssuance <= params.hardCap,
            "LendingTerm: hardcap reached"
        );

        // check the debt ceiling
        uint256 totalBorrowedCredit = ProfitManager(refs.profitManager)
            .totalBorrowedCredit();
        uint256 gaugeWeightTolerance = ProfitManager(refs.profitManager)
            .gaugeWeightTolerance();
        uint256 _debtCeiling = (GuildToken(refs.guildToken)
            .calculateGaugeAllocation(
                address(this),
                totalBorrowedCredit + borrowAmount
            ) * gaugeWeightTolerance) / 1e18;
        if (totalBorrowedCredit == 0) {
            // if the lending term is deprecated, `calculateGaugeAllocation` will return 0, and the borrow
            // should revert because the debt ceiling is reached (no borrows should be allowed anymore).
            // first borrow in the system does not check proportions of issuance, just that the term is not deprecated.
            require(_debtCeiling != 0, "LendingTerm: debt ceiling reached");
        } else {
            require(
                _postBorrowIssuance <= _debtCeiling,
                "LendingTerm: debt ceiling reached"
            );
        }

        // save loan in state
        loans[loanId] = Loan({
            borrower: borrower,
            borrowTime: block.timestamp,
            borrowAmount: borrowAmount,
            borrowCreditMultiplier: creditMultiplier,
            collateralAmount: collateralAmount,
            caller: address(0),
            callTime: 0,
            callDebt: 0,
            closeTime: 0
        });
        issuance = _postBorrowIssuance;
        if (params.maxDelayBetweenPartialRepay != 0) {
            lastPartialRepay[loanId] = block.timestamp;
        }

        // mint debt to the borrower
        RateLimitedMinter(refs.creditMinter).mint(borrower, borrowAmount);

        // pull the collateral from the borrower
        IERC20(params.collateralToken).safeTransferFrom(
            borrower,
            address(this),
            collateralAmount
        );

        // emit event
        emit LoanOpen(
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

    /// @notice add collateral on an open loan.
    /// a borrower might want to add collateral so that his position does not go underwater due to
    /// interests growing up over time.
    function _addCollateral(
        address borrower,
        bytes32 loanId,
        uint256 collateralToAdd
    ) internal {
        require(collateralToAdd != 0, "LendingTerm: cannot add 0");

        Loan storage loan = loans[loanId];

        // check the loan is open
        require(loan.borrowTime != 0, "LendingTerm: loan not found");
        require(loan.closeTime == 0, "LendingTerm: loan closed");
        require(loan.callTime == 0, "LendingTerm: loan called");

        // update loan in state
        loans[loanId].collateralAmount += collateralToAdd;

        // pull the collateral from the borrower
        IERC20(params.collateralToken).safeTransferFrom(
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

    /// @notice partially repay an open loan.
    /// a borrower might want to partially repay debt so that his position does not go underwater
    /// due to interests building up.
    /// some lending terms might also impose periodic partial repayments.
    function _partialRepay(
        address repayer,
        bytes32 loanId,
        uint256 debtToRepay
    ) internal {
        Loan storage loan = loans[loanId];

        // check the loan is open
        uint256 borrowTime = loan.borrowTime;
        require(borrowTime != 0, "LendingTerm: loan not found");
        require(
            borrowTime < block.timestamp,
            "LendingTerm: loan opened in same block"
        );
        require(loan.closeTime == 0, "LendingTerm: loan closed");
        require(loan.callTime == 0, "LendingTerm: loan called");

        // compute partial repayment
        uint256 loanDebt = getLoanDebt(loanId);
        require(debtToRepay < loanDebt, "LendingTerm: full repayment");
        uint256 percentRepaid = (debtToRepay * 1e18) / loanDebt; // [0, 1e18[
        uint256 borrowAmount = loan.borrowAmount;
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 principal = (borrowAmount * loan.borrowCreditMultiplier) /
            creditMultiplier;
        uint256 principalRepaid = (principal * percentRepaid) / 1e18;
        uint256 interestRepaid = debtToRepay - principalRepaid;
        uint256 issuanceDecrease = (borrowAmount * percentRepaid) / 1e18;
        require(
            principalRepaid != 0 && interestRepaid != 0,
            "LendingTerm: repay too small"
        );
        require(
            debtToRepay >= (loanDebt * params.minPartialRepayPercent) / 1e18,
            "LendingTerm: repay below min"
        );
        require(
            borrowAmount - issuanceDecrease >
                ProfitManager(refs.profitManager).minBorrow(),
            "LendingTerm: below min borrow"
        );

        // update loan in state
        loans[loanId].borrowAmount -= issuanceDecrease;
        lastPartialRepay[loanId] = block.timestamp;
        issuance -= issuanceDecrease;

        // pull the debt from the borrower
        CreditToken(refs.creditToken).transferFrom(
            repayer,
            address(this),
            debtToRepay
        );

        // forward profit portion to the ProfitManager, burn the rest
        CreditToken(refs.creditToken).transfer(
            refs.profitManager,
            interestRepaid
        );
        ProfitManager(refs.profitManager).notifyPnL(
            address(this),
            int256(interestRepaid)
        );
        CreditToken(refs.creditToken).burn(principalRepaid);
        RateLimitedMinter(refs.creditMinter).replenishBuffer(principalRepaid);

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
        uint256 borrowTime = loan.borrowTime;
        require(borrowTime != 0, "LendingTerm: loan not found");
        require(
            borrowTime < block.timestamp,
            "LendingTerm: loan opened in same block"
        );
        require(loan.closeTime == 0, "LendingTerm: loan closed");
        require(loan.callTime == 0, "LendingTerm: loan called");

        // compute interest owed
        uint256 loanDebt = getLoanDebt(loanId);
        uint256 borrowAmount = loan.borrowAmount;
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 principal = (borrowAmount * loan.borrowCreditMultiplier) /
            creditMultiplier;
        uint256 interest = loanDebt - principal;

        /// pull debt from the borrower and replenish the buffer of available debt that can be minted.
        CreditToken(refs.creditToken).transferFrom(
            repayer,
            address(this),
            loanDebt
        );
        if (interest != 0) {
            // forward profit portion to the ProfitManager
            CreditToken(refs.creditToken).transfer(
                refs.profitManager,
                interest
            );

            // report profit
            ProfitManager(refs.profitManager).notifyPnL(
                address(this),
                int256(interest)
            );
        }

        // burn loan principal
        CreditToken(refs.creditToken).burn(principal);
        RateLimitedMinter(refs.creditMinter).replenishBuffer(principal);

        // close the loan
        loan.closeTime = block.timestamp;
        issuance -= borrowAmount;

        // return the collateral to the borrower
        IERC20(params.collateralToken).safeTransfer(
            loan.borrower,
            loan.collateralAmount
        );

        // emit event
        emit LoanClose(block.timestamp, loanId, LoanCloseType.Repay, loanDebt);
    }

    /// @notice repay an open loan
    function repay(bytes32 loanId) external {
        _repay(msg.sender, loanId);
    }

    /// @notice call a loan, the collateral will be auctioned to repay outstanding debt.
    /// Loans can be called only if the term has been offboarded or if a loan missed a periodic partialRepay.
    function _call(
        address caller,
        bytes32 loanId,
        address _auctionHouse
    ) internal {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        uint256 borrowTime = loan.borrowTime;
        require(loan.borrowTime != 0, "LendingTerm: loan not found");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // check that the loan is not already called
        require(loan.callTime == 0, "LendingTerm: loan called");

        // check that the loan can be called
        require(
            GuildToken(refs.guildToken).isDeprecatedGauge(address(this)) ||
                partialRepayDelayPassed(loanId),
            "LendingTerm: cannot call"
        );

        // check that the loan has been running for at least 1 block
        require(
            borrowTime < block.timestamp,
            "LendingTerm: loan opened in same block"
        );

        // update loan in state
        uint256 loanDebt = getLoanDebt(loanId);
        loans[loanId].callTime = block.timestamp;
        loans[loanId].callDebt = loanDebt;
        loans[loanId].caller = caller;

        // auction the loan collateral
        AuctionHouse(_auctionHouse).startAuction(loanId, loanDebt);

        // emit event
        emit LoanCall(block.timestamp, loanId);
    }

    /// @notice call a single loan
    function call(bytes32 loanId) external {
        _call(msg.sender, loanId, refs.auctionHouse);
    }

    /// @notice call a list of loans
    function callMany(bytes32[] memory loanIds) public {
        address _auctionHouse = refs.auctionHouse;
        for (uint256 i = 0; i < loanIds.length; i++) {
            _call(msg.sender, loanIds[i], _auctionHouse);
        }
    }

    /// @notice forgive a loan, marking its debt as a total loss to the system.
    /// The loan is closed (borrower keeps the CREDIT), and the collateral stays on the LendingTerm.
    /// Governance can later unstuck the collateral through `emergencyAction`.
    /// This function is made for emergencies where collateral is frozen or other reverting
    /// conditions on collateral transfers that prevent regular repay() or call() loan closing.
    function forgive(bytes32 loanId) external onlyCoreRole(CoreRoles.GOVERNOR) {
        Loan storage loan = loans[loanId];

        // check that the loan exists
        require(loan.borrowTime != 0, "LendingTerm: loan not found");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // close the loan
        loans[loanId].closeTime = block.timestamp;
        issuance -= loan.borrowAmount;

        // mark loan as a total loss
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 borrowAmount = loans[loanId].borrowAmount;
        uint256 principal = (borrowAmount *
            loans[loanId].borrowCreditMultiplier) / creditMultiplier;
        int256 pnl = -int256(principal);
        ProfitManager(refs.profitManager).notifyPnL(address(this), pnl);

        // set hardcap to 0 to prevent new borrows
        params.hardCap = 0;

        // emit event
        emit LoanClose(block.timestamp, loanId, LoanCloseType.Forgive, 0);
    }

    /// @notice callback from the auctionHouse when au auction concludes
    function onBid(
        bytes32 loanId,
        address bidder,
        uint256 collateralToBorrower,
        uint256 collateralToBidder,
        uint256 creditFromBidder
    ) external {
        // preliminary checks
        require(msg.sender == refs.auctionHouse, "LendingTerm: invalid caller");
        require(
            loans[loanId].callTime != 0 && loans[loanId].callDebt != 0,
            "LendingTerm: loan not called"
        );
        require(loans[loanId].closeTime == 0, "LendingTerm: loan closed");

        // sanity check on collateral movement
        // these should never fail for a properly implemented AuctionHouse contract
        // collateralOut == 0 if forgive() while in auctionHouse
        uint256 collateralOut = collateralToBorrower + collateralToBidder;
        require(
            collateralOut == loans[loanId].collateralAmount ||
                collateralOut == 0,
            "LendingTerm: invalid collateral movements"
        );

        // compute pnl
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 borrowAmount = loans[loanId].borrowAmount;
        uint256 principal = (borrowAmount *
            loans[loanId].borrowCreditMultiplier) / creditMultiplier;
        int256 pnl;
        uint256 interest;
        if (creditFromBidder >= principal) {
            interest = creditFromBidder - principal;
            pnl = int256(interest);
        } else {
            pnl = int256(creditFromBidder) - int256(principal);
            principal = creditFromBidder;
            require(
                collateralToBorrower == 0,
                "LendingTerm: invalid collateral movement"
            );
        }

        // save loan state
        loans[loanId].closeTime = block.timestamp;

        // pull credit from bidder
        if (creditFromBidder != 0) {
            CreditToken(refs.creditToken).transferFrom(
                bidder,
                address(this),
                creditFromBidder
            );
        }

        // burn credit principal, replenish buffer
        if (principal != 0) {
            CreditToken(refs.creditToken).burn(principal);
            RateLimitedMinter(refs.creditMinter).replenishBuffer(principal);
        }

        // handle profit & losses
        if (pnl != 0) {
            // forward profit, if any
            if (interest != 0) {
                CreditToken(refs.creditToken).transfer(
                    refs.profitManager,
                    interest
                );
            }
            ProfitManager(refs.profitManager).notifyPnL(address(this), pnl);
        }

        // decrease issuance
        issuance -= borrowAmount;

        // send collateral to borrower
        if (collateralToBorrower != 0) {
            IERC20(params.collateralToken).safeTransfer(
                loans[loanId].borrower,
                collateralToBorrower
            );
        }

        // send collateral to bidder
        if (collateralToBidder != 0) {
            IERC20(params.collateralToken).safeTransfer(
                bidder,
                collateralToBidder
            );
        }

        emit LoanClose(
            block.timestamp,
            loanId,
            LoanCloseType.Call,
            creditFromBidder
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
            AuctionHouse(refs.auctionHouse).nAuctionsInProgress() == 0,
            "LendingTerm: auctions in progress"
        );

        refs.auctionHouse = _newValue;
    }

    /// @notice set the hardcap of CREDIT mintable in this term.
    /// allows to update a term's arbitrary hardcap without doing a gauge & loans migration.
    function setHardCap(
        uint256 _newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        params.hardCap = _newValue;
    }
}
