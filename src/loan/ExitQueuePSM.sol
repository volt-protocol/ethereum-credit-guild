// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

/// @notice Variation of the SimplePSM contract that allow users holding CREDIT to enter in the exit queue
/// to have their CREDIT automatically redeemed when another user mint some CREDIT
contract ExitQueuePSM is SimplePSM {
    using SafeERC20 for ERC20;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    /// @notice This is the value of "amountIn" that, if remaining, will not be
    /// taken from the exit queue but using the super._mint() function to avoid
    /// rounding errors with the possible discounted price of the exit queue tickets
    uint256 public immutable ROUNDING_ERROR_AMOUNT;

    /// @notice the minimum amount required to enter the exit queue
    /// this is needed to avoid spamming issues
    uint256 public immutable MIN_AMOUNT;

    /// @notice The delay between a user entering the queue and the same user trying to exit the queue
    /// this is needed to avoid spamming issues
    uint256 public immutable MIN_WITHDRAW_DELAY;

    /// @notice represent a user's ticket in the ExitQueue
    struct ExitQueueTicket {
        uint256 amountRemaining; // amount of CREDIT left in the ticket
        address owner; // owner of the CREDIT
        uint64 feePercent; // fees percentage. 0.1e18 is 10%
        uint64 timestamp;
    }

    /// @notice mapping of ticketId => ExitQueueTicket
    /// this is where all the tickets data are stored
    mapping(bytes32 => ExitQueueTicket) internal _tickets;

    /// @notice ordered queue of ticket ids
    /// front of the queue is the first ticket to be used when minting
    /// back of the queue is the last ticket to be used when minting
    /// @dev if the queue is empty, the contract act as a SimplePSM
    DoubleEndedQueue.Bytes32Deque public queue;

    /// @notice Event emitted upon entering the exit queue
    /// @param owner Owner of the CREDIT
    /// @param amount Amount of CREDIT being entered into the queue
    /// @param feePercent Fee percentage for the redemption
    /// @param timestamp Timestamp when the ticket is created
    /// @param ticketId Unique identifier for the exit queue ticket
    event ExitQueueUpdate(
        address indexed owner,
        bytes32 indexed ticketId,
        uint256 indexed timestamp,
        uint256 amount,
        uint64 feePercent
    );

    /// @notice Constructor for ExitQueuePSM
    /// @param _core Address of the core contract
    /// @param _profitManager Address of the ProfitManager contract
    /// @param _credit Address of the Credit token
    /// @param _pegToken Address of the pegged token
    /// @param _minAmount Minimum amount of CREDIT required to enter the exit queue
    /// @param _minWithdrawDelay Minimum delay required before withdrawing from the exit queue
    /// @param _roundingErrorAmount The min amount used
    constructor(
        address _core,
        address _profitManager,
        address _credit,
        address _pegToken,
        uint256 _minAmount,
        uint256 _minWithdrawDelay,
        uint256 _roundingErrorAmount
    ) SimplePSM(_core, _profitManager, _credit, _pegToken) {
        MIN_AMOUNT = _minAmount;
        MIN_WITHDRAW_DELAY = _minWithdrawDelay;
        ROUNDING_ERROR_AMOUNT = _roundingErrorAmount; // example 100 wei
    }

    /// @notice Retrieves the first ticket in the queue
    /// @return ticket The first ticket in the exit queue
    function getFirstTicket()
        public
        view
        returns (ExitQueueTicket memory ticket)
    {
        bytes32 frontTicketId = queue.front();
        return _tickets[frontTicketId];
    }

    /// @notice Retrieves the length of the queue
    /// @dev Utility function, to be used externally
    /// @return The current length of the queue
    function getQueueLength() external view returns (uint256) {
        return queue.length();
    }

    /// @notice Retrieves the total amount of credit in the queue and the total cost in peg token including the discount fees
    /// @dev Utility function, to be used externally
    /// @return totalCredit Total amount of CREDIT in the queue
    /// @return totalCostPegToken Total cost in peg tokens for the CREDIT in the queue
    function getTotalCreditInQueue()
        external
        view
        returns (uint256 totalCredit, uint256 totalCostPegToken)
    {
        uint256 creditMultiplier = ProfitManager(profitManager)
            .creditMultiplier();

        for (uint256 i = 0; i < queue.length(); i++) {
            bytes32 ticketId = queue.at(i);
            uint256 amount = _tickets[ticketId].amountRemaining;
            uint256 costPegToken = (((amount * creditMultiplier) /
                1e18 /
                decimalCorrection) * (1e18 - _tickets[ticketId].feePercent)) /
                1e18;
            totalCredit += amount;
            totalCostPegToken += costPegToken;
        }
    }

    /// @notice Retrieves a ticket by its ID
    /// @dev Utility function, to be used externally
    /// @param ticketId The unique identifier for the exit queue ticket
    /// @return ticket The exit queue ticket corresponding to the given ID
    function getTicketById(
        bytes32 ticketId
    ) external view returns (ExitQueueTicket memory ticket) {
        return _tickets[ticketId];
    }

    /// @notice Withdraws a ticket from the queue.
    /// @dev Parameters are used to determine the ticketId
    /// @param amount The initial amount when creating the ticket (used to generate the ticketId when entering the exit queue)
    /// @param feePct The fee percentage of the ticket
    /// @param timestamp The timestamp of the ticket creation
    function withdrawTicket(
        uint256 amount,
        uint64 feePct,
        uint256 timestamp
    ) external {
        require(
            timestamp + MIN_WITHDRAW_DELAY < block.timestamp,
            "ExitQueuePSM: withdraw delay not elapsed"
        );

        bytes32 ticketId = _getTicketId(
            ExitQueueTicket({
                amountRemaining: amount,
                owner: msg.sender,
                timestamp: uint64(timestamp),
                feePercent: feePct
            })
        );

        ExitQueueTicket storage storedTicket = _tickets[ticketId];

        require(
            storedTicket.timestamp != 0,
            "ExitQueuePSM: cannot find ticket"
        );

        require(
            storedTicket.amountRemaining != 0,
            "ExitQueuePSM: no amount to withdraw"
        );

        // here we don't delete the ticket in the tickets mapping so that
        // the delete can be done during the mint (to get gas refund to the minter)
        uint256 amountToSend = storedTicket.amountRemaining;
        storedTicket.amountRemaining = 0;
        CreditToken(credit).transfer(msg.sender, amountToSend);
        emit ExitQueueUpdate(msg.sender, ticketId, block.timestamp, 0, feePct);
    }

    /// @notice Enters the exit queue with a ticket
    /// @dev must have approved the PSM for the 'creditAmount'
    /// @dev if feePct > 0, the feePct must be higher than the fee of the current front ticket
    /// @param creditAmount The amount of CREDIT to enter into the queue
    /// @param feePct The fee percentage for entering the queue. 0.01e18 = 1%
    function enterExitQueue(uint256 creditAmount, uint64 feePct) public {
        require(creditAmount >= MIN_AMOUNT, "ExitQueuePSM: amount too low");
        require(feePct < 1e18, "ExitQueuePSM: fee should be < 100%");

        ExitQueueTicket memory ticket = ExitQueueTicket({
            amountRemaining: creditAmount,
            owner: msg.sender,
            timestamp: uint64(block.timestamp),
            feePercent: feePct
        });

        bytes32 ticketId = _getTicketId(ticket);
        require(
            _tickets[ticketId].timestamp == 0,
            "ExitQueuePSM: exit queue ticket already saved"
        );

        // transfer tokens to the PSM
        CreditToken(credit).transferFrom(
            msg.sender,
            address(this),
            creditAmount
        );

        // save the exit queue ticket to the tickets mapping
        _tickets[ticketId] = ticket;

        if (feePct == 0 || queue.empty()) {
            // no fees or queue empty, push to the back of the queue
            queue.pushBack(ticketId);
        } else {
            ExitQueueTicket memory frontTicket = getFirstTicket();
            require(
                frontTicket.feePercent < feePct,
                "ExitQueuePSM: can only undercut queue front"
            );

            queue.pushFront(ticketId);
        }

        emit ExitQueueUpdate(
            msg.sender,
            ticketId,
            block.timestamp,
            creditAmount,
            feePct
        );
    }

    /// @notice mint `amountOut` CREDIT to address `to` for `amountIn` underlying tokens
    /// the amountOut can be superior to the result of 'getMintAmountOut' because if the exit queue
    /// holds ticket with discount, then the amountIn cost will be lower than previously assumed
    /// @dev Internal function to mint CREDIT to an address for a given amount of underlying tokens
    /// @param to Address to mint CREDIT to
    /// @param amountIn Amount of underlying tokens
    /// @return amountOut The amount of credit minted
    function _mint(
        address to,
        uint256 amountIn
    ) internal override returns (uint256 amountOut) {
        if (queue.empty()) {
            return super._mint(to, amountIn);
        }

        uint256 creditMultiplier = ProfitManager(profitManager)
            .creditMultiplier();

        // this is the amountIn left to be used to mint CREDIT
        uint256 amountInLeft = amountIn;
        amountOut = 0;

        while (amountInLeft > ROUNDING_ERROR_AMOUNT && !queue.empty()) {
            // get the first item in the exit queue
            bytes32 frontTicketId = queue.front();
            ExitQueueTicket storage frontTicket = _tickets[frontTicketId];
            // discount is 100% - feePercent, if fee percent is 10%
            // then discount is 100% - 10% = 90%, which is the pct
            // we will use to compute the real amountIn price
            uint64 discount = 1e18 - frontTicket.feePercent;

            uint256 maxAmountOutBuyableAtDiscount = (((amountInLeft *
                decimalCorrection *
                1e18) / creditMultiplier) * 1e18) / discount;

            // amountOutFromTicket is the amount we take from the ticket
            // it can be less than the ticket is holding if amountInLeft to mint
            // is not enough to buy all the ticket's holdings
            uint256 amountOutFromTicket = frontTicket.amountRemaining >
                maxAmountOutBuyableAtDiscount
                ? maxAmountOutBuyableAtDiscount
                : frontTicket.amountRemaining;

            frontTicket.amountRemaining -= amountOutFromTicket;

            emit ExitQueueUpdate(
                msg.sender,
                frontTicketId,
                block.timestamp,
                frontTicket.amountRemaining,
                frontTicket.feePercent
            );

            // compute the pegToken price for this amount of tokens,
            // using the discounted value + 1 wei
            uint256 realAmountInCost = (((amountOutFromTicket *
                creditMultiplier) /
                1e18 /
                decimalCorrection) * discount) / 1e18;

            amountOut += amountOutFromTicket;
            amountInLeft -= realAmountInCost;

            // send realAmountInCost to ticket owner
            ERC20(pegToken).safeTransferFrom(
                msg.sender,
                frontTicket.owner,
                realAmountInCost
            );

            // if ticket completely drained, remove from the queue and the tickets mapping
            if (frontTicket.amountRemaining == 0) {
                queue.popFront();
                // get a bit of gas refund
                delete _tickets[frontTicketId];
            }
        }

        // check if the amountInLeft to be minted is 0, this is the case when all the minting
        // was done using exit queue tickets
        if (amountInLeft == 0) {
            // if so, just send the token as the user would have already paid the
            // pegToken to exitQueue owner(s)
            CreditToken(credit).transfer(to, amountOut);
        } else {
            if (amountOut > 0) {
                // send the credits obtained from the exit queue, if any
                CreditToken(credit).transfer(to, amountOut);
            }

            uint256 minted = super._mint(to, amountInLeft);
            amountOut += minted;
        }
    }

    /// @dev Internal function to generate a unique ID for an exit queue ticket
    /// @param ticket The exit queue ticket
    /// @return queueTicketId The unique identifier for the exit queue ticket
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
