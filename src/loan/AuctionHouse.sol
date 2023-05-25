// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

// TODO:
// - safeTransfer on collateralToken
// - add events
// - consider if some functions should be pausable

/// @notice Auction House contract of the Ethereum Credit Guild,
/// where collateral of borrowers is auctioned to cover their CREDIT debt.
contract AuctionHouse is CoreRef {

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
        uint256 debtAmount;
        uint256 ltvBuffer;
        uint256 callFeeAmount;
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
    /// @param callFeeDiscount true if the call fee should be discounted in the beginning of the auction
    function startAuction(bytes32 loanId, uint256 debtAmount, bool callFeeDiscount) external whenNotPaused {
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
            debtAmount: debtAmount,
            ltvBuffer: LendingTerm(msg.sender).ltvBuffer(),
            callFeeAmount: !callFeeDiscount ? 0 : loan.borrowAmount * LendingTerm(msg.sender).callFee() / 1e18
        });

        // pull collateral
        ERC20(_collateralToken).transferFrom(msg.sender, address(this), loan.collateralAmount);
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
            if (_collateralAmount - collateralReceived > minCollateralLeft) {
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

        // pull CREDIT from the bidder and burn it
        if (creditAsked != 0) {
            ERC20(creditToken).transferFrom(msg.sender, address(this), creditAsked);
            RateLimitedCreditMinter(creditMinter).replenishBuffer(creditAsked);
            CreditToken(creditToken).burn(creditAsked);
        }

        // transfer collateral to bidder
        address _collateralToken = auctions[loanId].collateralToken;
        if (collateralReceived != 0) {
            ERC20(_collateralToken).transfer(msg.sender, collateralReceived);
        }

        // transfer what is left of collateral to borrower
        uint256 _collateralAmount = auctions[loanId].collateralAmount;
        uint256 collateralLeft = _collateralAmount - collateralReceived;
        if (collateralLeft != 0) {
            ERC20(_collateralToken).transfer(auctions[loanId].borrower, collateralLeft);
        }

        // if loan was unsafe, or lending terms have been offboarded since auction start,
        // reimburse the call fee to caller.
        uint256 minCollateralLeft = _collateralAmount * auctions[loanId].ltvBuffer / 1e18;
        if (collateralLeft <= minCollateralLeft) {
            uint256 _debtAmount = auctions[loanId].debtAmount;
            RateLimitedCreditMinter(creditMinter).mint(auctions[loanId].caller, auctions[loanId].callFeeAmount);

            // if bad debt has been created, notify gauge system
            int256 pnl = int256(creditAsked) - int256(_debtAmount);
            if (pnl < 0) {
                GuildToken(guildToken).notifyPnL(auctions[loanId].lendingTerm, pnl);
            }
        }
    }
}
