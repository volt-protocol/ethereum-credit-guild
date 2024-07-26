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
    /// @notice emitted when the auctionHouse reference is updated
    event SetAuctionHouse(uint256 indexed when, address auctionHouse);
    /// @notice emitted when the hardCap is updated
    event SetHardCap(uint256 indexed when, uint256 hardCap);

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Reference number of seconds per periods in which the interestRate is expressed.
    /// This is equal to 365.25 days.
    uint256 public constant YEAR = 31557600;

    struct Loan {
        address borrower; // address of a loan's borrower
        uint48 borrowTime; // the time the loan was initiated
        uint48 lastPartialRepay; // the time of last partial repay
        uint256 borrowAmount; // initial CREDIT debt of a loan
        uint256 borrowCreditMultiplier; // creditMultiplier when loan was opened
        uint256 collateralAmount; // balance of collateral token provided by the borrower
        address caller; // a caller of 0 indicates that the loan has not been called
        uint48 callTime; // a call time of 0 indicates that the loan has not been called
        uint48 closeTime; // the time the loan was closed (repaid or call+bid or forgive)
        uint256 callDebt; // the CREDIT debt when the loan was called
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
        bytes calldata _params
    ) public virtual {
        // can initialize only once
        assert(address(core()) == address(0));
        assert(_core != address(0));

        // initialize storage
        _setCore(_core);
        refs = _refs;
        params = abi.decode(_params, (LendingTermParams));

        // check parameters:
        // must be an ERC20 (maybe, at least it prevents dumb input mistakes)
        (bool success, bytes memory returned) = params.collateralToken.call(
            abi.encodeWithSelector(IERC20.totalSupply.selector)
        );
        require(
            success && returned.length == 32,
            "LendingTerm: invalid collateralToken"
        );

        require(
            params.maxDebtPerCollateralToken != 0, // must be able to mint non-zero debt
            "LendingTerm: invalid maxDebtPerCollateralToken"
        );

        require(
            params.interestRate < 1e18, // interest rate [0, 100[% APR
            "LendingTerm: invalid interestRate"
        );

        require(
            params.maxDelayBetweenPartialRepay < YEAR + 1, // periodic payment every [0, 1 year]
            "LendingTerm: invalid maxDelayBetweenPartialRepay"
        );

        require(
            params.minPartialRepayPercent < 1e18, // periodic payment sizes [0, 100[%
            "LendingTerm: invalid minPartialRepayPercent"
        );

        require(
            params.openingFee <= 0.1e18, // open fee expected [0, 10]%
            "LendingTerm: invalid openingFee"
        );

        require(
            params.hardCap != 0, // non-zero hardcap
            "LendingTerm: invalid hardCap"
        );

        // if one of the periodic payment parameter is used, both must be used
        if (
            params.minPartialRepayPercent != 0 ||
            params.maxDelayBetweenPartialRepay != 0
        ) {
            require(
                params.minPartialRepayPercent != 0 &&
                    params.maxDelayBetweenPartialRepay != 0,
                "LendingTerm: invalid periodic payment params"
            );
        }

        // events
        emit SetAuctionHouse(block.timestamp, _refs.auctionHouse);
        emit SetHardCap(block.timestamp, params.hardCap);
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

    /// @notice get reference 'profitManager' of this term
    function profitManager() external view returns (address) {
        return refs.profitManager;
    }

    /// @notice get reference 'creditToken' of this term
    function creditToken() external view returns (address) {
        return refs.creditToken;
    }

    /// @notice get reference 'auctionHouse' of this term
    function auctionHouse() external view returns (address) {
        return refs.auctionHouse;
    }

    /// @notice get a loan
    function getLoan(bytes32 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    /// @notice outstanding borrowed amount of a loan, including interests
    function getLoanDebt(bytes32 loanId) public view returns (uint256) {
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        return _getLoanDebt(loanId, creditMultiplier);
    }

    /// @notice outstanding borrowed amount of a loan, including interests,
    /// given a creditMultiplier
    function _getLoanDebt(
        bytes32 loanId,
        uint256 creditMultiplier
    ) internal virtual view returns (uint256) {
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
        loanDebt = (loanDebt * loan.borrowCreditMultiplier) / creditMultiplier;

        return loanDebt;
    }

    /// @notice maximum debt for a given amount of collateral
    function maxDebtForCollateral(
        uint256 collateralAmount
    ) public view returns (uint256) {
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        return _maxDebtForCollateral(collateralAmount, creditMultiplier);
    }

    /// @notice maximum debt for a given amount of collateral & creditMultiplier
    function _maxDebtForCollateral(
        uint256 collateralAmount,
        uint256 creditMultiplier
    ) internal view returns (uint256) {
        return
            (collateralAmount * params.maxDebtPerCollateralToken) /
            creditMultiplier;
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
            loans[loanId].lastPartialRepay <
            block.timestamp - params.maxDelayBetweenPartialRepay;
    }

    /// @notice returns the maximum amount of debt that can be issued by this term
    /// according to the current gauge allocations.
    /// Note that the debt ceiling can be lower than the current issuance under 2 conditions :
    /// - gauge votes are fewer than when last borrow happened (in % relative to other terms)
    /// - profitManager.totalIssuance() decreased since last borrow
    /// Note that borrowing term.debtCeiling() - term.issuance() could still revert if the
    /// credit minter buffer is not enough to mint the borrowAmount, or if the term's hardCap
    /// is set to a lower value than the debt ceiling.
    /// @dev this solves the following equation :
    /// borrowAmount + issuance <=
    /// (totalIssuance + borrowAmount) * gaugeWeight * gaugeWeightTolerance / totalWeight / 1e18
    /// which is the formula to check debt ceiling in the borrow function.
    /// This equation gives the maximum borrowable amount to achieve 100% utilization of the debt
    /// ceiling, and if we add the current issuance to it, we get the current debt ceiling.
    /// @param gaugeWeightDelta an hypothetical change in gauge weight
    /// @return the maximum amount of debt that can be issued by this term
    function debtCeiling(
        int256 gaugeWeightDelta
    ) public view returns (uint256) {
        address _guildToken = refs.guildToken; // cached SLOAD
        // if the term is deprecated, return 0 debtCeiling
        if (!GuildToken(_guildToken).isGauge(address(this))) {
            // intended side effect: if the gauge is deprecated, wait that all loans
            // are closed (liquidation auctions conclude) before allowing GUILD token
            // holders to decrement weight.
            return 0;
        }
        uint256 gaugeWeight = GuildToken(_guildToken).getGaugeWeight(
            address(this)
        );
        uint256 gaugeType = GuildToken(_guildToken).gaugeType(address(this));
        uint256 totalWeight = GuildToken(_guildToken).totalTypeWeight(
            gaugeType
        );
        if (gaugeWeightDelta < 0 && uint256(-gaugeWeightDelta) > gaugeWeight) {
            uint256 decrement = uint256(-gaugeWeightDelta);
            if (decrement > gaugeWeight || decrement > totalWeight) {
                // early return for cases where the hypothetical gaugeWeightDelta
                // would make the gaugeWeight or totalWeight <= 0.
                // This allows unchecked casting on the following lines.
                return 0;
            }
        }
        gaugeWeight = uint256(int256(gaugeWeight) + gaugeWeightDelta);
        totalWeight = uint256(int256(totalWeight) + gaugeWeightDelta);
        if (gaugeWeight == 0 || totalWeight == 0) {
            return 0; // no gauge vote or all gauges deprecated, 0 debt ceiling
        } else if (gaugeWeight == totalWeight) {
            // one gauge, unlimited debt ceiling
            return type(uint256).max;
        }
        uint256 _issuance = issuance; // cached SLOAD
        uint256 totalIssuance = ProfitManager(refs.profitManager)
            .totalIssuance();
        uint256 gaugeWeightTolerance = ProfitManager(refs.profitManager)
            .gaugeWeightTolerance();
        if (totalIssuance == 0 && gaugeWeight != 0) {
            // first-ever CREDIT mint on a non-zero gauge weight term
            // does not check the relative debt ceilings
            return type(uint256).max;
        }
        uint256 toleratedGaugeWeight = (gaugeWeight * gaugeWeightTolerance) /
            1e18;
        uint256 debtCeilingBefore = (totalIssuance * toleratedGaugeWeight) /
            totalWeight;
        // if already above cap, no more borrows allowed
        if (_issuance >= debtCeilingBefore) {
            return debtCeilingBefore;
        }
        /// @dev this can only underflow if gaugeWeightTolerance is < 1e18
        /// and that value is enforced >= 1e18 in the ProfitManager setter.
        uint256 remainingDebtCeiling = debtCeilingBefore - _issuance;
        if (toleratedGaugeWeight >= totalWeight) {
            // if the gauge weight is above 100% when we include tolerance,
            // the gauge relative debt ceilings are not constraining.
            return type(uint256).max;
        }
        /// @dev this can never underflow due to previous if() block
        uint256 otherGaugesWeight = totalWeight - toleratedGaugeWeight;

        uint256 maxBorrow = (remainingDebtCeiling * totalWeight) /
            otherGaugesWeight;
        return _issuance + maxBorrow;
    }

    /// @notice returns the debt ceiling without change to gauge weight
    function debtCeiling() public view returns (uint256) {
        return debtCeiling(0);
    }

    /// @notice initiate a new loan
    /// @param payer address depositing the collateral
    /// @param borrower address getting the borrowed funds
    /// @param borrowAmount amount of gUSDC borrowed
    /// @param collateralAmount the collateral amount deposited
    function _borrow(
        address payer,
        address borrower,
        uint256 borrowAmount,
        uint256 collateralAmount
    ) internal virtual returns (bytes32 loanId) {
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
        uint256 maxBorrow = _maxDebtForCollateral(
            collateralAmount,
            creditMultiplier
        );
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
        uint256 _debtCeiling = debtCeiling();
        require(
            _postBorrowIssuance <= _debtCeiling,
            "LendingTerm: debt ceiling reached"
        );

        // save loan in state
        loans[loanId] = Loan({
            borrower: borrower,
            borrowTime: uint48(block.timestamp),
            lastPartialRepay: uint48(block.timestamp),
            borrowAmount: borrowAmount,
            borrowCreditMultiplier: creditMultiplier,
            collateralAmount: collateralAmount,
            caller: address(0),
            callTime: 0,
            closeTime: 0,
            callDebt: 0
        });
        issuance = _postBorrowIssuance;

        // notify ProfitManager of issuance change
        ProfitManager(refs.profitManager).notifyPnL(
            address(this),
            0,
            int256(borrowAmount)
        );

        // mint debt to the borrower
        RateLimitedMinter(refs.creditMinter).mint(borrower, borrowAmount);

        // pull the collateral from the borrower
        _transferCollateralIn(payer, collateralAmount);

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
        loanId = _borrow(
            msg.sender,
            msg.sender,
            borrowAmount,
            collateralAmount
        );
    }

    /// @notice initiate a new loan on behalf of someone else
    function borrowOnBehalf(
        uint256 borrowAmount,
        uint256 collateralAmount,
        address onBehalfOf
    ) external whenNotPaused returns (bytes32 loanId) {
        loanId = _borrow(
            msg.sender,
            onBehalfOf,
            borrowAmount,
            collateralAmount
        );
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
        _transferCollateralIn(borrower, collateralToAdd);

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
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 loanDebt = _getLoanDebt(loanId, creditMultiplier);
        require(debtToRepay < loanDebt, "LendingTerm: full repayment");
        uint256 borrowAmount = loan.borrowAmount;
        uint256 principalRepaid = (borrowAmount *
            loan.borrowCreditMultiplier *
            debtToRepay) /
            creditMultiplier /
            loanDebt;
        uint256 interestRepaid = debtToRepay - principalRepaid;
        uint256 issuanceDecrease = (borrowAmount * debtToRepay) / loanDebt;

        require(principalRepaid != 0, "LendingTerm: repay too small");
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
        loans[loanId].lastPartialRepay = uint48(block.timestamp);
        issuance -= issuanceDecrease;

        // pull the debt from the borrower
        CreditToken(refs.creditToken).transferFrom(
            repayer,
            address(this),
            debtToRepay
        );

        // forward profit portion to the ProfitManager, burn the rest
        if (interestRepaid != 0) {
            CreditToken(refs.creditToken).transfer(
                refs.profitManager,
                interestRepaid
            );
            ProfitManager(refs.profitManager).notifyPnL(
                address(this),
                int256(interestRepaid),
                -int256(issuanceDecrease)
            );
        }
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
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 loanDebt = _getLoanDebt(loanId, creditMultiplier);
        uint256 borrowAmount = loan.borrowAmount;
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
                int256(interest),
                -int256(borrowAmount)
            );
        }

        // burn loan principal
        CreditToken(refs.creditToken).burn(principal);
        RateLimitedMinter(refs.creditMinter).replenishBuffer(principal);

        // close the loan
        loan.closeTime = uint48(block.timestamp);
        issuance -= borrowAmount;

        // return the collateral to the borrower
        _transferCollateralOut(loan.borrower, loan.collateralAmount);

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
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 loanDebt = _getLoanDebt(loanId, creditMultiplier);
        require(
            GuildToken(refs.guildToken).isDeprecatedGauge(address(this)) ||
                loanDebt >
                _maxDebtForCollateral(
                    loans[loanId].collateralAmount,
                    creditMultiplier
                ) ||
                partialRepayDelayPassed(loanId),
            "LendingTerm: cannot call"
        );

        // check that the loan has been running for at least 1 block
        require(
            borrowTime < block.timestamp,
            "LendingTerm: loan opened in same block"
        );

        // update loan in state
        loans[loanId].callTime = uint48(block.timestamp);
        loans[loanId].callDebt = loanDebt;
        loans[loanId].caller = caller;

        // auction the loan collateral
        AuctionHouse(_auctionHouse).startAuction(loanId);

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

        // check that the loan is not already called
        require(loan.callTime == 0, "LendingTerm: loan called");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "LendingTerm: loan closed");

        // close the loan
        loans[loanId].closeTime = uint48(block.timestamp);
        uint256 borrowAmount = loans[loanId].borrowAmount;
        issuance -= borrowAmount;

        // mark loan as a total loss
        uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 principal = (borrowAmount *
            loans[loanId].borrowCreditMultiplier) / creditMultiplier;
        int256 pnl = -int256(principal);
        ProfitManager(refs.profitManager).notifyPnL(
            address(this),
            pnl,
            -int256(borrowAmount)
        );

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
        loans[loanId].closeTime = uint48(block.timestamp);

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
            ProfitManager(refs.profitManager).notifyPnL(
                address(this),
                pnl,
                -int256(borrowAmount)
            );
        }

        // decrease issuance
        issuance -= borrowAmount;

        // send collateral to borrower
        if (collateralToBorrower != 0) {
            _transferCollateralOut(loans[loanId].borrower, collateralToBorrower);
        }

        // send collateral to bidder
        if (collateralToBidder != 0) {
            _transferCollateralOut(bidder, collateralToBidder);
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
        emit SetAuctionHouse(block.timestamp, _newValue);
    }

    /// @notice set the hardcap of CREDIT mintable in this term.
    /// allows to update a term's arbitrary hardcap without doing a gauge & loans migration.
    function setHardCap(
        uint256 _newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        params.hardCap = _newValue;
        emit SetHardCap(block.timestamp, _newValue);
    }

    /// @notice transfer collateral in to the term
    function _transferCollateralIn(address from, uint256 amount) internal virtual {
        IERC20(params.collateralToken).safeTransferFrom(from, address(this), amount);
    }

    /// @notice transfer collateral out of the term
    function _transferCollateralOut(address to, uint256 amount) internal virtual {
        IERC20(params.collateralToken).safeTransfer(to, amount);
    }
}
