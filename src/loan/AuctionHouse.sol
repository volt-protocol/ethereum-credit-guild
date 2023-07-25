// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

/// @notice Auction House contract of the Ethereum Credit Guild,
/// where collateral of borrowers is auctioned to cover their CREDIT debt.
contract AuctionHouse is CoreRef {
    using SafeERC20 for IERC20;

    // events for the lifecycle of loans that happen in the auction house
    event LoanBid(uint256 indexed when, bytes32 indexed loanId, uint256 collateralSold, uint256 collateralReturned, uint256 creditRecovered, uint256 creditIssued);

    /// @notice number of seconds before the midpoint of the auction, at which time the
    /// mechanism switches from "offer an increasing amount of collateral" to
    /// "ask a decreasing amount of debt".
    uint256 public constant MIDPOINT = 650; // 10m50s

    /// @notice maximum duration of auctions, in seconds.
    /// with a midpoint of 10m50s and an auction duration of 30min, and a block every 13s,
    /// first phase will last around 50 blocks and each block will offer an additional
    /// 1/(650/13)=2% of the collateral during the first phase. During the second phase,
    /// every block will ask 1/((1800-650)/13)=1.13% less CREDIT in each block.
    uint256 public constant AUCTION_DURATION = 1800; // 30 minutes

    /// @notice reference to the GUILD token
    address public guildToken;

    /// @notice reference to the credit minter contract
    address public creditMinter;

    /// @notice reference to the CREDIT token
    address public creditToken;

    struct Auction {
        uint256 startTime;
        uint256 endTime;
        address lendingTerm;
        address caller;
        address borrower;
        address collateralToken;
        uint256 collateralAmount;
        uint256 borrowAmount;
        uint256 debtAmount;
        uint256 ltvBuffer;
        uint256 callFeeAmount;
        bool loanCalled;
    }

    /// @notice the list of all auctions that existed or are still active.
    /// key is the loanId for which the auction has been created.
    mapping(bytes32=>Auction) public auctions;

    constructor(
        address _core,
        address _guildToken,
        address _creditMinter,
        address _creditToken
    ) CoreRef(_core) {
        guildToken = _guildToken;
        creditMinter = _creditMinter;
        creditToken = _creditToken;
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
    function startAuction(bytes32 loanId, uint256 debtAmount, bool loanCalled) external whenNotPaused {
        // check that caller is an active lending term
        require(GuildToken(guildToken).isGauge(msg.sender), "AuctionHouse: invalid gauge");

        // check the loan exists in calling lending term and has been closed in the current block
        LendingTerm.Loan memory loan = LendingTerm(msg.sender).getLoan(loanId);
        require(loan.closeTime == block.timestamp, "AuctionHouse: loan previously closed");

        // sanity check: debt is at least the borrowed amount
        require(debtAmount >= loan.borrowAmount, "AuctionHouse: negative interest");

        // check auction for this loan has not already been created
        require(auctions[loanId].startTime == 0, "AuctionHouse: auction exists");

        // save auction in state
        address _collateralToken = LendingTerm(msg.sender).collateralToken();
        auctions[loanId] = Auction({
            startTime: block.timestamp,
            endTime: 0,
            lendingTerm: msg.sender,
            caller: loan.caller,
            borrower: loan.borrower,
            collateralToken: _collateralToken,
            collateralAmount: loan.collateralAmount,
            borrowAmount: loan.borrowAmount,
            debtAmount: debtAmount,
            ltvBuffer: LendingTerm(msg.sender).ltvBuffer(),
            callFeeAmount: loan.borrowAmount * LendingTerm(msg.sender).callFee() / 1e18,
            loanCalled: loanCalled
        });

        // pull collateral
        IERC20(_collateralToken).safeTransferFrom(msg.sender, address(this), loan.collateralAmount);
    }

    /// @notice Get the bid details for an active auction.
    /// During the first half of the auction, an increasing amount of the collateral is offered, for the full CREDIT amount.
    /// During the second half of the action, all collateral is offered, for a decreasing CREDIT amount.
    /// If less collateral than the LTV buffer is left after the bid (loan with bad debt or in danger zone), 
    /// the CREDIT amount asked is increased by the call fee, to reimburse the call fee to the caller, instead of letting
    /// the borrower recover more of their collateral.
    function getBidDetail(bytes32 loanId) public view returns (uint256 collateralReceived, uint256 creditAsked) {
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
        if (block.timestamp < _startTime + MIDPOINT) {
            // ask for the full debt
            creditAsked = auctions[loanId].debtAmount;

            // compute amount of collateral received
            uint256 elapsed = block.timestamp - _startTime; // [0, MIDPOINT[
            uint256 _collateralAmount = auctions[loanId].collateralAmount; // SLOAD
            collateralReceived = _collateralAmount * elapsed / MIDPOINT;

            // discount debt by the call fee if collateral left is above LTV buffer
            uint256 minCollateralLeft = _collateralAmount * auctions[loanId].ltvBuffer / 1e18;
            if (_collateralAmount - collateralReceived > minCollateralLeft && auctions[loanId].loanCalled) {
                creditAsked -= auctions[loanId].callFeeAmount;
            }
        }
        // second phase of the auction, where less and less CREDIT is asked
        else if (block.timestamp < _startTime + AUCTION_DURATION) {
            // receive the full collateral
            collateralReceived = auctions[loanId].collateralAmount;

            // compute amount of CREDIT to ask
            uint256 PHASE_2_DURATION = AUCTION_DURATION - MIDPOINT;
            uint256 elapsed = block.timestamp - _startTime - MIDPOINT; // [0, PHASE_2_DURATION[
            uint256 _debtAmount = auctions[loanId].debtAmount;
            creditAsked = _debtAmount - _debtAmount * elapsed / PHASE_2_DURATION;
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
    function bid(bytes32 loanId) external whenNotPaused {
        // this view function will revert if the auction is not started,
        // or if the auction is already ended.
        (uint256 collateralReceived, uint256 creditAsked) = getBidDetail(loanId);

        // close the auction in state
        auctions[loanId].endTime = block.timestamp;

        // pull CREDIT from the bidder
        address _creditToken = creditToken;
        if (creditAsked != 0) {
            IERC20(_creditToken).transferFrom(msg.sender, address(this), creditAsked);
        }

        // transfer collateral to bidder
        address _collateralToken = auctions[loanId].collateralToken;
        if (collateralReceived != 0) {
            IERC20(_collateralToken).safeTransfer(msg.sender, collateralReceived);
        }

        // transfer what is left of collateral to borrower
        uint256 collateralLeft = auctions[loanId].collateralAmount - collateralReceived;
        if (collateralLeft != 0) {
            IERC20(_collateralToken).safeTransfer(auctions[loanId].borrower, collateralLeft);
        }

        // if loan was unsafe, or lending terms have been offboarded since auction start,
        // reimburse the call fee to caller.
        bool _loanCalled = auctions[loanId].loanCalled;
        uint256 _callFeeAmount = auctions[loanId].callFeeAmount;
        uint256 protocolInput = creditAsked + (_loanCalled ? _callFeeAmount : 0);
        uint256 protocolOutput = auctions[loanId].borrowAmount;
        uint256 creditToBurn = protocolInput;
        if (
            _loanCalled &&
            (
                collateralLeft < (auctions[loanId].collateralAmount * auctions[loanId].ltvBuffer / 1e18)
                || GuildToken(guildToken).isGauge(auctions[loanId].lendingTerm) == false
            )
        ) {
            CreditToken(_creditToken).transfer(auctions[loanId].caller, _callFeeAmount);
            protocolOutput += _callFeeAmount;
            creditToBurn -= _callFeeAmount;
        }

        // end of the lifecycle of a loan, notify of profit & losses created in the system.
        // send profits to the GUILD token & burn the rest of CREDIT received in the liquidation
        int256 pnl = int256(protocolInput) - int256(protocolOutput);
        if (pnl > 0) {
            CreditToken(_creditToken).transfer(guildToken, uint256(pnl));
            creditToBurn -= uint256(pnl);
        }
        if (creditToBurn != 0) {
            RateLimitedCreditMinter(creditMinter).replenishBuffer(creditToBurn);
            CreditToken(_creditToken).burn(creditToBurn);
        }
        GuildToken(guildToken).notifyPnL(auctions[loanId].lendingTerm, pnl);

        // if losses were realized, set the harcap of the lending term to 0 to avoid new borrows.
        if (pnl < 0) {
            LendingTerm(auctions[loanId].lendingTerm).setHardCap(0);
        }

        // emit event
        emit LoanBid(block.timestamp, loanId, collateralReceived, collateralLeft, protocolInput, protocolOutput);
    }

    /// @notice forgive a loan, by marking the debt as a total loss & without attempting to move the collateral.
    /// @dev this is meant to be used when an auction concludes without anyone pulling the
    /// collateral of a loan, even if 0 CREDIT is asked in return. This situation could arise
    /// if collateral assets are frozen within the auction house contract.
    function forgive(bytes32 loanId) external whenNotPaused {
        // this view function will revert if the auction is not started,
        // or if the auction is already ended.
        ( , uint256 creditAsked) = getBidDetail(loanId);
        require(creditAsked == 0, "AuctionHouse: ongoing auction");

        // close the auction in state
        auctions[loanId].endTime = block.timestamp;

        // if loan was called, reimburse the call fee to caller.
        uint256 _callFeeAmount = auctions[loanId].callFeeAmount;
        if (auctions[loanId].loanCalled && _callFeeAmount != 0) {
            CreditToken(creditToken).transfer(auctions[loanId].caller, _callFeeAmount);
        }

        // notify loss created in the system
        address _lendingTerm = auctions[loanId].lendingTerm;
        uint256 _borrowAmount = auctions[loanId].borrowAmount;
        GuildToken(guildToken).notifyPnL(
            _lendingTerm,
            -int256(_borrowAmount)
        );

        // set the harcap of the lending term to 0 to avoid new borrows.
        LendingTerm(_lendingTerm).setHardCap(0);

        // emit event
        emit LoanBid(block.timestamp, loanId, 0, 0, 0, _borrowAmount);
    }
}
