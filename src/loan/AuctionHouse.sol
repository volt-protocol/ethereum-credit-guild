// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";

/// @notice Auction House contract of the Ethereum Credit Guild,
/// where collateral of borrowers is auctioned to cover their CREDIT debt.
contract AuctionHouse is CoreRef {
    /// @notice emitted when au action starts
    event AuctionStart(
        uint256 indexed when,
        bytes32 indexed loanId,
        address collateralToken,
        uint256 collateralAmount,
        uint256 callDebt
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

    struct Auction {
        uint256 startTime;
        uint256 endTime;
        address lendingTerm;
        uint256 collateralAmount;
        uint256 callDebt;
    }

    /// @notice the list of all auctions that existed or are still active.
    /// key is the loanId for which the auction has been created.
    /// @dev see public getAuction(loanId) getter.
    mapping(bytes32 => Auction) internal auctions;

    /// @notice number of auctions currently in progress
    uint256 public nAuctionsInProgress;

    constructor(
        address _core,
        uint256 _midPoint,
        uint256 _auctionDuration
    ) CoreRef(_core) {
        require(_midPoint < _auctionDuration, "AuctionHouse: invalid params");
        midPoint = _midPoint;
        auctionDuration = _auctionDuration;
    }

    /// @notice get a full auction structure from storage
    function getAuction(bytes32 loanId) external view returns (Auction memory) {
        return auctions[loanId];
    }

    /// @notice start the auction of the collateral of a loan, to be exchanged for CREDIT,
    /// in order to pay the debt of a loan.
    /// @param loanId the ID of the loan which collateral is auctioned
    /// @param callDebt the amount of CREDIT debt to recover from the collateral auction
    function startAuction(bytes32 loanId, uint256 callDebt) external {
        // check that caller is a lending term that still has PnL reporting role
        require(
            core().hasRole(CoreRoles.GAUGE_PNL_NOTIFIER, msg.sender),
            "AuctionHouse: invalid caller"
        );

        // check the loan exists in calling lending term and has been called in the current block
        LendingTerm.Loan memory loan = LendingTerm(msg.sender).getLoan(loanId);
        require(
            loan.callTime == block.timestamp,
            "AuctionHouse: loan previously called"
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
            callDebt: callDebt
        });
        nAuctionsInProgress++;

        // emit event
        emit AuctionStart(
            block.timestamp,
            loanId,
            LendingTerm(msg.sender).collateralToken(),
            loan.collateralAmount,
            callDebt
        );
    }

    /// @notice Get the bid details for an active auction.
    /// During the first half of the auction, an increasing amount of the collateral is offered, for the full CREDIT amount.
    /// During the second half of the action, all collateral is offered, for a decreasing CREDIT amount.
    function getBidDetail(
        bytes32 loanId
    ) public view returns (uint256 collateralReceived, uint256 creditAsked) {
        // check the auction for this loan exists
        uint256 _startTime = auctions[loanId].startTime;
        require(_startTime != 0, "AuctionHouse: invalid auction");

        // check the auction for this loan isn't ended
        require(auctions[loanId].endTime == 0, "AuctionHouse: auction ended");

        // assertion should never fail because when an auction is created,
        // block.timestamp is recorded as the auction start time, and we check in previous
        // lines that start time != 0, so the auction has started.
        assert(block.timestamp >= _startTime);

        // first phase of the auction, where more and more collateral is offered
        if (block.timestamp < _startTime + midPoint) {
            // ask for the full debt
            creditAsked = auctions[loanId].callDebt;

            // compute amount of collateral received
            uint256 elapsed = block.timestamp - _startTime; // [0, midPoint[
            uint256 _collateralAmount = auctions[loanId].collateralAmount; // SLOAD
            collateralReceived = (_collateralAmount * elapsed) / midPoint;
        }
        // second phase of the auction, where less and less CREDIT is asked
        else if (block.timestamp < _startTime + auctionDuration) {
            // receive the full collateral
            collateralReceived = auctions[loanId].collateralAmount;

            // compute amount of CREDIT to ask
            uint256 PHASE_2_DURATION = auctionDuration - midPoint;
            uint256 elapsed = block.timestamp - _startTime - midPoint; // [0, PHASE_2_DURATION[
            uint256 _callDebt = auctions[loanId].callDebt; // SLOAD
            creditAsked = _callDebt - (_callDebt * elapsed) / PHASE_2_DURATION;
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
    /// @dev as a bidder, you must approve CREDIT tokens on the LendingTerm contract associated
    /// with the loan `getAuction(loanId).lendingTerm`, not on the AuctionHouse itself.
    function bid(bytes32 loanId) external {
        // this view function will revert if the auction is not started,
        // or if the auction is already ended.
        (uint256 collateralReceived, uint256 creditAsked) = getBidDetail(
            loanId
        );
        require(creditAsked != 0, "AuctionHouse: cannot bid 0");

        // close the auction in state
        auctions[loanId].endTime = block.timestamp;
        nAuctionsInProgress--;

        // notify LendingTerm of auction result
        address _lendingTerm = auctions[loanId].lendingTerm;
        LendingTerm(_lendingTerm).onBid(
            loanId,
            msg.sender,
            auctions[loanId].collateralAmount - collateralReceived, // collateralToBorrower
            collateralReceived, // collateralToBidder
            creditAsked // creditFromBidder
        );

        // emit event
        emit AuctionEnd(
            block.timestamp,
            loanId,
            LendingTerm(_lendingTerm).collateralToken(),
            collateralReceived, // collateralSold
            creditAsked // debtRecovered
        );
    }

    /// @notice forgive a loan, by marking the debt as a total loss
    /// @dev this is meant to be used when an auction concludes without anyone bidding,
    /// even if 0 CREDIT is asked in return. This situation could arise
    /// if collateral assets are frozen within the lending term contract.
    function forgive(bytes32 loanId) external {
        // this view function will revert if the auction is not started,
        // or if the auction is already ended.
        (, uint256 creditAsked) = getBidDetail(loanId);
        require(creditAsked == 0, "AuctionHouse: ongoing auction");

        // close the auction in state
        auctions[loanId].endTime = block.timestamp;
        nAuctionsInProgress--;

        // notify LendingTerm of auction result
        address _lendingTerm = auctions[loanId].lendingTerm;
        LendingTerm(_lendingTerm).onBid(
            loanId,
            msg.sender,
            0, // collateralToBorrower
            0, // collateralToBidder
            0 // creditFromBidder
        );

        // emit event
        emit AuctionEnd(
            block.timestamp,
            loanId,
            LendingTerm(_lendingTerm).collateralToken(),
            0, // collateralSold
            0 // debtRecovered
        );
    }
}
