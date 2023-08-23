// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";

/// @notice Auction House contract of the Ethereum Credit Guild,
/// where collateral of borrowers is auctioned to cover their CREDIT debt.
contract AuctionHouse is CoreRef {
    using SafeERC20 for IERC20;

    /// @notice emitted when au action starts
    event AuctionStart(
        uint256 indexed when,
        bytes32 indexed loanId,
        address collateralToken,
        uint256 collateralAmount,
        uint256 debtAmount
    );
    /// @notice emitted when au anction ends
    event AuctionEnd(
        uint256 indexed when,
        bytes32 indexed loanId,
        address collateralToken,
        uint256 collateralSold,
        uint256 debtRecovered
    );

    /// @notice number of seconds before the midpoint of the auction, at which time the
    /// mechanism switches from "offer an increasing amount of collateral" to
    /// "ask a decreasing amount of debt".
    uint256 public immutable midPoint;

    /// @notice maximum duration of auctions, in seconds.
    /// with a midpoint of 650 (10m50s) and an auction duration of 30min, and a block every
    /// 13s, first phase will last around 50 blocks and each block will offer an additional
    /// 1/(650/13)=2% of the collateral during the first phase. During the second phase,
    /// every block will ask 1/((1800-650)/13)=1.13% less CREDIT in each block.
    uint256 public immutable auctionDuration;

    /// @notice liquidation penalty, expressed as a percentage with 18 decimals.
    /// e.g. a value of 0.1e18 will apply a 10% penalty on liquidations in danger zone.
    /// during the auction, if the collateral left is below the LTV buffer, instead of
    /// returning all collateral left to the borrower, 10% will be sent to the caller,
    /// and the borrower who didn't maintain a healthy LTV will incur a small loss.
    uint256 public immutable dangerPenalty;

    struct Auction {
        uint256 startTime;
        uint256 endTime;
        address lendingTerm;
        uint256 collateralAmount;
        uint256 borrowAmount;
        uint256 debtAmount;
        uint256 ltvBuffer;
        uint256 callFeeAmount;
        bool loanCalled;
    }

    struct AuctionResult {
        uint256 collateralToBorrower;
        uint256 collateralToCaller;
        uint256 collateralToBidder;
        uint256 creditFromBidder;
        uint256 creditToCaller;
        uint256 creditToBurn;
        uint256 creditToProfit;
        int256 pnl;
    }

    /// @notice the list of all auctions that existed or are still active.
    /// key is the loanId for which the auction has been created.
    mapping(bytes32 => Auction) public auctions;

    /// @notice number of auctions currently in progress
    uint256 public nAuctionsInProgress;

    constructor(
        address _core,
        uint256 _midPoint,
        uint256 _auctionDuration,
        uint256 _dangerPenalty
    ) CoreRef(_core) {
        require(_midPoint < _auctionDuration, "AuctionHouse: invalid params");
        midPoint = _midPoint;
        auctionDuration = _auctionDuration;
        dangerPenalty = _dangerPenalty;
    }

    /// @notice get a full auction structure from storage
    function getAuction(bytes32 loanId) external view returns (Auction memory) {
        return auctions[loanId];
    }

    /// @notice start the auction of the collateral of a loan, to be exchanged for CREDIT,
    /// in order to pay the debt of a loan.
    /// @param loanId the ID of the loan which collateral is auctioned
    /// @param debtAmount the amount of CREDIT debt to recover from the collateral auction
    /// @param loanCalled true if the call fee has been collected
    function startAuction(
        bytes32 loanId,
        uint256 debtAmount,
        bool loanCalled
    ) external whenNotPaused {
        // check that caller is a lending term that hasn't been offboarded
        require(
            core().hasRole(CoreRoles.GAUGE_PNL_NOTIFIER, msg.sender),
            "AuctionHouse: invalid caller"
        );

        // check the loan exists in calling lending term and has been closed in the current block
        LendingTerm.Loan memory loan = LendingTerm(msg.sender).getLoan(loanId);
        require(
            loan.closeTime == block.timestamp,
            "AuctionHouse: loan previously closed"
        );

        // sanity check: debt is at least the borrowed amount
        require(
            debtAmount >= loan.borrowAmount,
            "AuctionHouse: negative interest"
        );

        // check auction for this loan has not already been created
        require(
            auctions[loanId].startTime == 0,
            "AuctionHouse: auction exists"
        );

        // save auction in state
        auctions[loanId] = Auction({
            startTime: block.timestamp,
            endTime: 0,
            lendingTerm: msg.sender,
            collateralAmount: loan.collateralAmount,
            borrowAmount: loan.borrowAmount,
            debtAmount: debtAmount,
            ltvBuffer: LendingTerm(msg.sender).ltvBuffer(),
            callFeeAmount: (loan.borrowAmount *
                LendingTerm(msg.sender).callFee()) / 1e18,
            loanCalled: loanCalled
        });
        nAuctionsInProgress++;

        // emit event
        emit AuctionStart(
            block.timestamp,
            loanId,
            LendingTerm(msg.sender).collateralToken(),
            loan.collateralAmount,
            debtAmount
        );
    }

    /// @notice Get the bid details for an active auction.
    /// During the first half of the auction, an increasing amount of the collateral is offered, for the full CREDIT amount.
    /// During the second half of the action, all collateral is offered, for a decreasing CREDIT amount.
    /// If less collateral than the LTV buffer is left after the bid (loan with bad debt or in danger zone),
    /// the CREDIT amount asked is increased by the call fee, to reimburse the call fee to the caller, instead of letting
    /// the borrower recover more of their collateral.
    function getBidDetail(
        bytes32 loanId
    ) public view returns (uint256 collateralReceived, uint256 creditAsked) {
        // check the auction for this loan exists
        uint256 _startTime = auctions[loanId].startTime;
        require(_startTime != 0, "AuctionHouse: invalid auction");

        // check the auction for this loan isn't ended
        require(auctions[loanId].endTime == 0, "AuctionHouse: auction ended");

        // invalid state that should never happen because when an auction is created,
        // block.timestamp is recorded as the auction start time, and we check in previous
        // lines that start time != 0, so the auction has started.
        assert(block.timestamp >= _startTime);

        // first phase of the auction, where more and more collateral is offered
        if (block.timestamp < _startTime + midPoint) {
            // ask for the full debt
            creditAsked = auctions[loanId].debtAmount;

            // compute amount of collateral received
            uint256 elapsed = block.timestamp - _startTime; // [0, midPoint[
            uint256 _collateralAmount = auctions[loanId].collateralAmount; // SLOAD
            collateralReceived = (_collateralAmount * elapsed) / midPoint;

            // discount debt by the call fee if collateral left is above LTV buffer
            uint256 minCollateralLeft = (_collateralAmount *
                auctions[loanId].ltvBuffer) / 1e18;
            if (
                _collateralAmount - collateralReceived > minCollateralLeft &&
                auctions[loanId].loanCalled
            ) {
                creditAsked -= auctions[loanId].callFeeAmount;
            }
        }
        // second phase of the auction, where less and less CREDIT is asked
        else if (block.timestamp < _startTime + auctionDuration) {
            // receive the full collateral
            collateralReceived = auctions[loanId].collateralAmount;

            // compute amount of CREDIT to ask
            uint256 PHASE_2_DURATION = auctionDuration - midPoint;
            uint256 elapsed = block.timestamp - _startTime - midPoint; // [0, PHASE_2_DURATION[
            uint256 _debtAmount = auctions[loanId].debtAmount;
            creditAsked =
                _debtAmount -
                (_debtAmount * elapsed) /
                PHASE_2_DURATION;
        }
        // second phase fully elapsed, anyone can receive the full collateral and give 0 CREDIT
        // in practice, somebody should have taken the arb before we reach this condition.
        else {
            // receive the full collateral
            collateralReceived = auctions[loanId].collateralAmount;
            //creditAsked = 0; // implicit
        }
    }

    /// @notice bid for an active auction
    /// @dev as a bidder, you must approve CREDIT tokens on the LendingTerm contract
    /// associated with the loan, not on the AuctionHouse itself.
    function bid(bytes32 loanId) external whenNotPaused {
        // this view function will revert if the auction is not started,
        // or if the auction is already ended.
        (uint256 collateralReceived, uint256 creditAsked) = getBidDetail(
            loanId
        );

        // close the auction in state
        auctions[loanId].endTime = block.timestamp;
        nAuctionsInProgress--;

        // initialize the auction result object
        bool _loanCalled = auctions[loanId].loanCalled;
        uint256 _callFeeAmount = auctions[loanId].callFeeAmount;
        AuctionResult memory result;
        result.collateralToBorrower =
            auctions[loanId].collateralAmount -
            collateralReceived;
        //result.collateralToCaller = 0; // implicit
        result.collateralToBidder = collateralReceived;
        result.creditFromBidder = creditAsked;
        //result.creditToCaller = 0; // implicit
        result.creditToBurn = creditAsked + (_loanCalled ? _callFeeAmount : 0);
        //result.creditToProfit = 0; // implicit
        result.pnl =
            int256(result.creditToBurn) -
            int256(auctions[loanId].borrowAmount);

        // if loan was unsafe, reimburse the call fee to caller and allocate them
        // part of the collateral that is left.
        uint256 minCollateralLeft = ((result.collateralToBorrower +
            collateralReceived) * auctions[loanId].ltvBuffer) / 1e18;
        if (_loanCalled && result.collateralToBorrower < minCollateralLeft) {
            result.creditToCaller += _callFeeAmount;
            result.creditToBurn -= _callFeeAmount;
            result.pnl -= int256(_callFeeAmount);
            result.collateralToCaller +=
                (result.collateralToBorrower * dangerPenalty) /
                1e18;
            result.collateralToBorrower -= result.collateralToCaller;
        }

        // if profit is positive, do not burn the credit from profit, instead
        // it will be distributed as profits by the system.
        if (result.pnl > 0) {
            result.creditToBurn -= uint256(result.pnl);
            result.creditToProfit = uint256(result.pnl);
        }

        // notify LendingTerm of auction result
        LendingTerm(auctions[loanId].lendingTerm).onBid(
            loanId,
            msg.sender,
            result
        );

        // emit event
        emit AuctionEnd(
            block.timestamp,
            loanId,
            LendingTerm(auctions[loanId].lendingTerm).collateralToken(),
            collateralReceived,
            creditAsked
        );
    }

    /// @notice forgive a loan, by marking the debt as a total loss
    /// @dev this is meant to be used when an auction concludes without anyone bidding,
    /// even if 0 CREDIT is asked in return. This situation could arise
    /// if collateral assets are frozen within the lending term contract.
    function forgive(bytes32 loanId) external whenNotPaused {
        // this view function will revert if the auction is not started,
        // or if the auction is already ended.
        (, uint256 creditAsked) = getBidDetail(loanId);
        require(creditAsked == 0, "AuctionHouse: ongoing auction");

        // close the auction in state
        auctions[loanId].endTime = block.timestamp;
        nAuctionsInProgress--;

        // initialize the auction result object
        // if loan was called, reimburse the call fee to caller.
        bool _loanCalled = auctions[loanId].loanCalled;
        AuctionResult memory result;
        //result.collateralToBorrower = 0; // implicit
        //result.collateralToCaller = 0; // implicit
        //result.collateralToBidder = 0; // implicit
        //result.creditFromBidder = 0; // implicit
        result.creditToCaller = _loanCalled
            ? auctions[loanId].callFeeAmount
            : 0;
        //result.creditToBurn = 0; // implicit
        //result.creditToProfit = 0; // implicit
        result.pnl = -int256(auctions[loanId].borrowAmount);

        // notify LendingTerm of auction result
        LendingTerm(auctions[loanId].lendingTerm).onBid(
            loanId,
            msg.sender,
            result
        );

        // emit event
        emit AuctionEnd(
            block.timestamp,
            loanId,
            LendingTerm(auctions[loanId].lendingTerm).collateralToken(),
            0,
            0
        );
    }
}
