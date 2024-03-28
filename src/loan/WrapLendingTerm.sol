// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

/// @notice Lending Term that can wrap collateral to another token.
/// This can be used to denominate loans in native WETH / DAI / etc (usually the peg
/// token of the market), and allow convenient leverage on yield-bearing version of these
/// assets (rETH, sDAI, ...).
abstract contract WrapLendingTerm is LendingTerm {
    using SafeERC20 for IERC20;

    /// @notice emitted when a loan's wrap status changes
    event LoanWrapStatusChange(
        uint256 indexed when,
        bytes32 indexed loanId,
        WrapStatus status
    );

    enum WrapStatus {
        UNWRAPPED,
        WRAPPING,
        WRAPPED,
        UNWRAPPING
    }

    struct WrapData {
        WrapStatus status;
        bool borrowerWithdrawn;
        bool bidderWithdrawn;
        address bidder; 
        uint256 collateralToBidder;
        uint256 wrappedAmount;
    }
    
    /// @notice wrap status of loans
    mapping(bytes32 => WrapData) internal loanWrapData;

    /// @notice the token address collateral tokens can be wrapped to
    function wrappedCollateralToken() public view virtual returns (address);

    /// @notice override to emit the LoanWrapStatusChange->UNWRAPPED event
    function _borrow(
        address payer,
        address borrower,
        uint256 borrowAmount,
        uint256 collateralAmount
    ) internal override returns (bytes32 loanId) {
        loanId = super._borrow(payer, borrower, borrowAmount, collateralAmount);
        emit LoanWrapStatusChange(block.timestamp, loanId, WrapStatus.UNWRAPPED);
    }

    /// @notice override to prevent withdrawal from borrower/bidder
    function _forgive(bytes32 loanId) internal override {
        super._forgive(loanId);
        loanWrapData[loanId].borrowerWithdrawn = true;
        loanWrapData[loanId].bidderWithdrawn = true;
    }

    /// @notice to add collateral, loan collateral must be unwrapped
    function _addCollateral(
        address borrower,
        bytes32 loanId,
        uint256 collateralToAdd
    ) internal override {
        require(loanWrapData[loanId].status == WrapStatus.UNWRAPPED, "WrapLendingTerm: collateral wrapped");
        super._addCollateral(borrower, loanId, collateralToAdd);
    }

    /// @notice to repay, loan collateral must not be in the process of wrapping or
    /// unwrapping. If repaying a loan that has wrapped collateral, the borrower will
    /// receive wrapped collateral tokens.
    function _repay_returnCollateralToBorrower(
        bytes32 loanId,
        address borrower,
        uint256 collateralAmount
    ) internal override {
        WrapData memory _wrapData = loanWrapData[loanId];
        if (_wrapData.status == WrapStatus.UNWRAPPED) {
            IERC20(params.collateralToken).safeTransfer(
                borrower,
                collateralAmount
            );
            loanWrapData[loanId].borrowerWithdrawn = true;
        }
        else if (_wrapData.status == WrapStatus.WRAPPED) {
            IERC20(wrappedCollateralToken()).safeTransfer(
                borrower,
                _wrapData.wrappedAmount
            );
            loanWrapData[loanId].borrowerWithdrawn = true;
        }
        else {
            revert("WrapLendingTerm: invalid wrap state");
        }
    }

    /// @notice if the loan has been called while it had wrapped collateral,
    /// record the result of the auction
    function _onBid_handleAuctionResult(
        bytes32 loanId,
        address bidder,
        uint256 collateralToBorrower,
        uint256 collateralToBidder,
        uint256 creditFromBidder,
        uint256 borrowAmount,
        uint256 principal,
        uint256 interest,
        int256 pnl
    ) internal override {
        WrapData memory _wrapData = loanWrapData[loanId];

        // if the loan is unwrapped, keep default behavior
        if (_wrapData.status == WrapStatus.UNWRAPPED) {
            super._onBid_handleAuctionResult(
                loanId,
                bidder,
                collateralToBorrower,
                collateralToBidder,
                creditFromBidder,
                borrowAmount,
                principal,
                interest,
                pnl
            );
            loanWrapData[loanId] = WrapData({
                status: _wrapData.status,
                borrowerWithdrawn: true,
                bidderWithdrawn: true,
                bidder: bidder, 
                collateralToBidder: collateralToBidder,
                wrappedAmount: _wrapData.wrappedAmount
            });
        }
        // else, store auction result and wait for unwrapping.
        // debt is settled during the bid, but collateral token movements
        // happend later at the request of borrower or bidder.
        else {
            loanWrapData[loanId] = WrapData({
                status: _wrapData.status,
                borrowerWithdrawn: _wrapData.borrowerWithdrawn,
                bidderWithdrawn: _wrapData.bidderWithdrawn,
                bidder: bidder, 
                collateralToBidder: collateralToBidder,
                wrappedAmount: _wrapData.wrappedAmount
            });

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
        }
    }

    /// @notice request wrapping of a loan collateral
    function requestWrap(bytes32 loanId) external {
        Loan storage loan = loans[loanId];

        // only borrower can request a wrap
        require(msg.sender == loan.borrower, "WrapLendingTerm: unauthorized");

        // check that the loan exists
        require(loan.borrowTime != 0, "WrapLendingTerm: loan not found");

        // check that the loan is not already called
        require(loan.callTime == 0, "WrapLendingTerm: loan called");

        // check that the loan is not already closed
        require(loan.closeTime == 0, "WrapLendingTerm: loan closed");

        // check wrap status
        require(loanWrapData[loanId].status == WrapStatus.UNWRAPPED, "WrapLendingTerm: invalid wrap state");

        _doRequestWrap(loanId, loan.collateralAmount);
    }

    /// @notice fulfill wrapping of a loan collateral
    /// @dev permissionless, `requestWrap` should have recorded in state the information
    /// needed to perform this step.
    function fulfillWrap(bytes32 loanId) external {
        // check wrap status
        require(loanWrapData[loanId].status == WrapStatus.WRAPPING, "WrapLendingTerm: invalid wrap state");

        _doFulfillWrap(loanId);
    }

    /// @notice request unwrapping of a loan collateral
    function requestUnwrap(bytes32 loanId) external {
        Loan storage loan = loans[loanId];
        WrapData memory _wrapData = loanWrapData[loanId];

        // only borrower can request a wrap
        require(msg.sender == loan.borrower || msg.sender == _wrapData.bidder, "WrapLendingTerm: unauthorized");

        // check that the loan exists
        require(loan.borrowTime != 0, "WrapLendingTerm: loan not found");

        // check wrap status
        require(_wrapData.status == WrapStatus.WRAPPED, "WrapLendingTerm: invalid wrap state");

        _doRequestUnwrap(loanId, _wrapData.wrappedAmount);
    }

    /// @notice fulfill unwrapping of a loan collateral
    /// @dev permissionless, `requestUnwrap` should have recorded in state the information
    /// needed to perform this step.
    function fulfillUnwrap(bytes32 loanId) external {
        // check wrap status
        require(loanWrapData[loanId].status == WrapStatus.UNWRAPPING, "WrapLendingTerm: invalid wrap state");

        _doFulfillUnwrap(loanId);
    }

    /// @notice withdraw collateral after loan has been closed.
    /// This function might be needed if the loan was called & someone bid while the loan
    /// was not in an UNWRAPPED state. In this situation, the collateral has to be unwrapped
    /// and then the borrower & bidder can withdraw their parts of the collateral.
    function withdrawCollateralAfterLoanClose(bytes32 loanId) external {
        // check wrap status
        WrapData memory _wrapData = loanWrapData[loanId];
        require(_wrapData.status == WrapStatus.UNWRAPPED, "WrapLendingTerm: invalid wrap state");

        // check that the loan is closed
        require(loans[loanId].closeTime != 0, "WrapLendingTerm: loan not closed");

        address _borrower = loans[loanId].borrower;
        if (msg.sender == _borrower) {
            require(!_wrapData.borrowerWithdrawn, "WrapLendingTerm: already withdrawn");
            loanWrapData[loanId].borrowerWithdrawn = true;

            IERC20(params.collateralToken).safeTransfer(
                _borrower,
                loans[loanId].collateralAmount - _wrapData.collateralToBidder
            );
        } else if (msg.sender == _wrapData.bidder) {
            require(!_wrapData.bidderWithdrawn, "WrapLendingTerm: already withdrawn");
            loanWrapData[loanId].bidderWithdrawn = true;

            IERC20(params.collateralToken).safeTransfer(
                _borrower,
                _wrapData.collateralToBidder
            );
        } else {
            revert("WrapLendingTerm: unauthorized");
        }
    }

    /// @dev This function can check KYC if needed, record wrapping action id if needed, send tokens or approve / call external function, etc
    /// @dev if wrapping is asynchronous, MUST set loanWrapData[loanId].status to WRAPPING
    /// @dev if wrapping is atomic, MUST set loanWrapData[loanId].status to WRAPPED and record loanWrapData[loanId].wrappedAmount
    /// @dev MUST emit LoanWrapStatusChange(block.timestamp, loanId, WrapStatus.WRAPPING or WrapStatus.WRAPPED);
    function _doRequestWrap(bytes32 loanId, uint256 collateralAmount) internal virtual;

    /// @dev MUST set loanWrapData[loanId].status to WRAPPED and record loanWrapData[loanId].wrappedAmount
    /// @dev MUST emit LoanWrapStatusChange(block.timestamp, loanId, WrapStatus.WRAPPED);
    function _doFulfillWrap(bytes32/* loanId*/) internal virtual {
        revert("WrapLendingTerm: not implemented");
    }

    /// @dev This function can check KYC if needed, record unwrapping action id if needed, send tokens or approve / call external function, etc
    /// @dev if wrapping is asynchronous, MUST set loanWrapData[loanId].status to UNWRAPPING
    /// @dev if wrapping is atomic, MUST set loanWrapData[loanId].status to UNWRAPPED and update loans[loanId].collateralAmount or loanWrapData[loanId].collateralToBidder
    /// @dev MUST emit LoanWrapStatusChange(block.timestamp, loanId, WrapStatus.UNWRAPPING or WrapStatus.UNWRAPPED);
    function _doRequestUnwrap(bytes32 loanId, uint256 wrappedAmount) internal virtual;

    /// @dev MUST set loanWrapData[loanId].status to UNWRAPPED and update loans[loanId].collateralAmount or loanWrapData[loanId].collateralToBidder
    /// @dev MUST emit LoanWrapStatusChange(block.timestamp, loanId, WrapStatus.UNWRAPPED);
    function _doFulfillUnwrap(bytes32/* loanId*/) internal virtual {
        revert("WrapLendingTerm: not implemented");
    }
}
