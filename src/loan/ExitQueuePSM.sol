// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";

import {console} from "@forge-std/console.sol";

/// @notice Variation of the SimplePSM contract that allow users holding CREDIT to enter in the exit queue
/// to have their CREDIT automatically redeemed when another user mint some CREDIT
contract ExitQueuePSM is SimplePSM {
    using SafeERC20 for ERC20;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    uint256 public immutable MIN_AMOUNT;
    uint256 public immutable MIN_WITHDRAW_DELAY;

    /// @notice represent a user place in the ExitQueue
    struct ExitQueueTicket {
        uint256 amountRemaining; // amount of CREDIT left in the ticket
        address owner; // owner of the CREDIT
        uint64 feePercent; // fees percentage. 0.1e18 is 10%
        uint64 timestamp;
    }

    DoubleEndedQueue.Bytes32Deque public queue;
    mapping(bytes32 => ExitQueueTicket) public tickets;

    /// @notice event emitted upon a redemption
    event EnterExitQueue(
        address indexed owner,
        uint256 amount,
        uint64 feePercent,
        uint256 timestamp,
        bytes32 ticketId
    );

    constructor(
        address _core,
        address _profitManager,
        address _credit,
        address _pegToken,
        uint256 _minAmount,
        uint256 _minWithdrawDelay
    ) SimplePSM(_core, _profitManager, _credit, _pegToken) {
        MIN_AMOUNT = _minAmount;
        MIN_WITHDRAW_DELAY = _minWithdrawDelay;
    }

    function getFirstTicket()
        public
        view
        returns (ExitQueueTicket memory ticket)
    {
        bytes32 frontTicketId = queue.front();
        return tickets[frontTicketId];
    }

    function getQueueLength() public view returns (uint256) {
        return queue.length();
    }

    function getTicketById(
        bytes32 ticketId
    ) public view returns (ExitQueueTicket memory ticket) {
        return tickets[ticketId];
    }

    function getTotalCreditInQueue()
        public
        view
        returns (uint256 totalCredit, uint256 totalCostPegToken)
    {
        for (uint256 i = 0; i < queue.length(); i++) {
            bytes32 ticketId = queue.at(i);
            uint256 amount = tickets[ticketId].amountRemaining;
            uint256 costPegToken = (getRedeemAmountOut(amount) *
                (1e18 - tickets[ticketId].feePercent)) / 1e18;
            totalCredit += amount;
            totalCostPegToken += costPegToken;
        }
    }

    function withdrawTicket(
        uint256 amount,
        uint64 feePct,
        uint64 timestamp
    ) public {
        require(
            timestamp + MIN_WITHDRAW_DELAY < block.timestamp,
            "ExitQueuePSM: withdraw delay not elapsed"
        );

        bytes32 ticketId = _getTicketId(
            ExitQueueTicket({
                amountRemaining: amount,
                owner: msg.sender,
                timestamp: timestamp,
                feePercent: feePct
            })
        );

        ExitQueueTicket storage storedTicket = tickets[ticketId];

        require(
            storedTicket.timestamp != 0,
            "ExitQueuePSM: cannot find ticket"
        );

        require(
            storedTicket.amountRemaining != 0,
            "ExitQueuePSM: no amount to withdraw"
        );

        storedTicket.amountRemaining = 0;
        ERC20(credit).safeTransfer(msg.sender, storedTicket.amountRemaining);
    }

    function enterExitQueue(uint256 creditAmount, uint64 feePct) public {
        require(creditAmount >= MIN_AMOUNT, "ExitQueuePSM: amount too low");
        require(feePct <= 1e18, "ExitQueuePSM: max fee is 100%");

        ExitQueueTicket memory ticket = ExitQueueTicket({
            amountRemaining: creditAmount,
            owner: msg.sender,
            timestamp: uint64(block.timestamp),
            feePercent: feePct
        });

        bytes32 ticketId = _getTicketId(ticket);
        require(
            tickets[ticketId].timestamp == 0,
            "ExitQueuePSM: exit queue ticket already saved"
        );

        // transfer tokens to the PSM
        ERC20(credit).safeTransferFrom(msg.sender, address(this), creditAmount);

        // save the exit queue ticket to the tickets mapping
        tickets[ticketId] = ticket;

        if (feePct == 0) {
            // no fees, push to the back of the queue
            queue.pushBack(ticketId);
        } else {
            bytes32 frontTicketId = queue.front();
            ExitQueueTicket memory frontTicket = tickets[frontTicketId];
            require(
                frontTicket.feePercent < feePct,
                "ExitQueuePSM: Can only outbid current high bidder"
            );

            queue.pushFront(ticketId);
        }

        emit EnterExitQueue(
            msg.sender,
            creditAmount,
            feePct,
            block.timestamp,
            ticketId
        );
    }

    /// @notice mint `amountOut` CREDIT to address `to` for `amountIn` underlying tokens
    function _mint(
        address to,
        uint256 amountIn
    ) internal override returns (uint256 amountOut) {
        if (queue.empty()) {
            return super._mint(to, amountIn);
        }

        uint256 creditMultiplier = ProfitManager(profitManager)
            .creditMultiplier();

        amountOut = (amountIn * decimalCorrection * 1e18) / creditMultiplier;
        uint256 currentAmountOut = 0;
        uint256 totalAmountInCost = 0;
        uint256 amountOutRemaining = amountOut;

        while (amountOutRemaining > 0 && !queue.empty()) {
            // get the first item in the exit queue
            bytes32 frontTicketId = queue.front();
            ExitQueueTicket storage frontTicket = tickets[frontTicketId];
            // discount is 100% - feePercent, if fee percent is 10%
            // then discount is 100% - 10% = 90%, which is the pct
            // we will use to compute the real amountIn price
            uint64 discount = 1e18 - frontTicket.feePercent;

            uint256 amountFromTicket = frontTicket.amountRemaining >
                amountOutRemaining
                ? amountOutRemaining
                : frontTicket.amountRemaining;

            frontTicket.amountRemaining -= amountFromTicket;

            if (frontTicket.amountRemaining == 0) {
                // remove ticketId from the queue
                queue.popFront();
                // get a bit of gas refund
                delete tickets[frontTicketId];
            }

            // compute the pegToken price for this amount of tokens, using the discounted value
            uint256 realAmountInCost = (((amountFromTicket * creditMultiplier) /
                1e18 /
                decimalCorrection) * discount) / 1e18;

            currentAmountOut += amountFromTicket;
            amountOutRemaining = amountOut - currentAmountOut;

            totalAmountInCost += realAmountInCost;

            // send realAmountInCost to ticket owner
            ERC20(pegToken).safeTransferFrom(
                msg.sender,
                frontTicket.owner,
                realAmountInCost
            );
        }

        // check if the currentAmountOut (from the exitQueue) is enough
        // for the user mint
        if (currentAmountOut == amountOut) {
            // if so, just send the token as the user would have already paid the
            // pegToken to exitQueue owner(s)
            ERC20(credit).safeTransfer(to, amountOut);
        } else {
            if (currentAmountOut > 0) {
                ERC20(credit).safeTransfer(to, currentAmountOut);
            }

            uint256 amountOutLeftToMint = amountOut - currentAmountOut;
            uint256 amountInCost = ((amountOutLeftToMint * creditMultiplier) /
                1e18 /
                decimalCorrection);
            totalAmountInCost += amountInCost;

            // ensure not spending more than amountIn
            require(totalAmountInCost <= amountIn, "");

            pegTokenBalance += amountInCost;
            ERC20(pegToken).safeTransferFrom(
                msg.sender,
                address(this),
                amountInCost
            );
            CreditToken(credit).mint(to, amountOutLeftToMint);
            emit Mint(block.timestamp, to, amountInCost, amountOutLeftToMint);
        }
    }

    function _getTicketId(
        ExitQueueTicket memory ticket
    ) internal pure returns (bytes32 queueTicketId) {
        queueTicketId = keccak256(
            abi.encodePacked(
                ticket.amountRemaining,
                ticket.owner,
                ticket.feePercent,
                ticket.timestamp
            )
        );
    }
}
