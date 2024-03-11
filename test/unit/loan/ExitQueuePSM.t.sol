// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest, console} from "@test/ECGTest.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {ExitQueuePSM} from "@src/loan/ExitQueuePSM.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

contract ExitQueuePSMUnitTest is ECGTest {
    address private governor = address(1);
    address private guardian = address(2);

    Core private core;
    ProfitManager public profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 token;
    ExitQueuePSM psm;

    uint256 MIN_AMOUNT = 100e18;
    uint256 MIN_DELAY = 100;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        token = new MockERC20();
        token.setDecimals(6);
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(address(core));
        psm = new ExitQueuePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(token),
            MIN_AMOUNT,
            MIN_DELAY
        );
        profitManager.initializeReferences(address(credit), address(guild));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(psm));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(profitManager));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(psm));
        core.grantRole(CoreRoles.CREDIT_REBASE_PARAMETERS, address(psm));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(42, address(this));
        guild.mint(address(this), 1e18);
        guild.incrementGauge(address(this), 1e18);

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(token), "token");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(psm), "exitqueuepsm");
        vm.label(address(this), "test");
    }

    // constructor params & public state getters
    function testInitialState() public {
        assertEq(address(psm.core()), address(core));
        assertEq(psm.profitManager(), address(profitManager));
        assertEq(psm.credit(), address(credit));
        assertEq(psm.pegToken(), address(token));
        assertEq(psm.decimalCorrection(), 1e12);

        // specifics for ExitQueuePSM
        assertEq(psm.MIN_AMOUNT(), MIN_AMOUNT);
        assertEq(psm.MIN_WITHDRAW_DELAY(), MIN_DELAY);
        (uint256 totalCredit, uint256 totalCostPegToken) = psm
            .getTotalCreditInQueue();
        assertEq(totalCredit, 0);
        assertEq(totalCostPegToken, 0);
    }

    // enforce that:
    // - mint moves a number of tokens equal to getMintAmountOut() i/o
    // - redeem moves a number of token equal to getRedeemAmountOut() i/o
    // - rounding errors are within 1 wei for a mint/redeem round-trip
    // same test as the simplePSM exactly, checks that when the queue is empty
    // the contracts performs just like the SimplePSM
    function testMintRedeem(uint256 input) public {
        uint256 mintIn = (input % 1e15) + 1; // [1, 1_000_000_000e6]

        // update creditMultiplier
        // this ensures that some fuzz entries will result in uneven divisions
        // and will create a min/redeem round-trip error of 1 wei.
        credit.mint(address(this), 100e18);
        assertEq(profitManager.creditMultiplier(), 1e18);
        profitManager.notifyPnL(address(this), -int256((input % 90e18) + 1), 0); // [0-90%] loss
        assertLt(profitManager.creditMultiplier(), 1.0e18 + 1);
        assertGt(profitManager.creditMultiplier(), 0.1e18 - 1);
        credit.burn(100e18);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(psm)), 0);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(psm.pegTokenBalance(), 0);

        // mint
        token.mint(address(this), mintIn);
        token.approve(address(psm), mintIn);
        psm.mint(address(this), mintIn);

        uint256 mintOut = psm.getMintAmountOut(mintIn);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), mintOut);
        assertEq(token.balanceOf(address(psm)), mintIn);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(psm.pegTokenBalance(), mintIn);

        // redeem
        credit.approve(address(psm), mintOut);
        psm.redeem(address(this), mintOut);

        uint256 redeemOut = psm.getRedeemAmountOut(mintOut);
        assertEq(token.balanceOf(address(this)), redeemOut);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(psm)), mintIn - redeemOut);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(psm.pegTokenBalance(), mintIn - redeemOut);

        // max error of 1 wei for doing a round trip
        assertLt(mintIn - redeemOut, 2);
    }

    // test mintAndEnterRebase
    // same test as the simplePSM exactly, checks that when the queue is empty
    // the contracts performs just like the SimplePSM
    function testMintAndEnterRebase() public {
        uint256 mintIn = 20_000e6;

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(psm)), 0);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(credit.isRebasing(address(this)), false);

        // mint
        token.mint(address(this), mintIn);
        token.approve(address(psm), mintIn);
        psm.mintAndEnterRebase(mintIn);

        uint256 mintOut = 20_000e18;
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), mintOut);
        assertEq(token.balanceOf(address(psm)), mintIn);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(credit.isRebasing(address(this)), true);

        // cannot enter mintAndEnterRebase twice
        token.mint(address(this), mintIn);
        token.approve(address(psm), mintIn);
        vm.expectRevert("SimplePSM: already rebasing");
        psm.mintAndEnterRebase(mintIn);
    }

    // this tests 3 successives enterExitQueue()
    // the first with 100 credits and 0 fee
    // the second with 200 credits and 10% fee
    // the third with 300 credits and 0 fee
    // and this checks that the 200 credit ticket is the first even after the third ticket arrived
    function testEnterExitQueue(uint256 input) public {
        uint256 creditAmount = (input % 1e15) + MIN_AMOUNT; // [MIN_AMOUNT, 1_000_000_000e6]

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(psm)), 0);

        credit.mint(address(this), creditAmount);
        credit.approve(address(psm), creditAmount);
        psm.enterExitQueue(creditAmount, 0);

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(psm)), creditAmount);
        (uint256 totalCredit, uint256 totalCostPegToken) = psm
            .getTotalCreditInQueue();
        assertEq(totalCredit, creditAmount);
        assertEq(totalCostPegToken, psm.getRedeemAmountOut(creditAmount));
    }

    function testEnterExitQueueWithPriority() public {
        uint256 firstAmount = 100e18;
        uint256 firstPegTokenCost = psm.getRedeemAmountOut(firstAmount);
        uint256 secondAmount = 200e18;
        uint64 secondAmountFee = 0.1e18;
        uint256 secondPegTokenCost = (psm.getRedeemAmountOut(secondAmount) *
            (1e18 - secondAmountFee)) / 1e18;
        uint256 thirdAmount = 300e18;
        uint256 thirdPegTokenCost = psm.getRedeemAmountOut(thirdAmount);

        credit.mint(address(this), firstAmount);
        credit.approve(address(psm), firstAmount);
        psm.enterExitQueue(firstAmount, 0);
        bytes32 firstTicketId = _getTicketId(
            ExitQueuePSM.ExitQueueTicket({
                amountRemaining: firstAmount,
                owner: address(this),
                feePercent: 0,
                timestamp: uint64(block.timestamp)
            })
        );

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(psm)), firstAmount);
        (uint256 totalCredit, uint256 totalCostPegToken) = psm
            .getTotalCreditInQueue();
        assertEq(totalCredit, firstAmount);
        assertEq(totalCostPegToken, firstPegTokenCost);
        assertEq(psm.getQueueLength(), 1);
        assertEq(psm.getTicketById(firstTicketId).amountRemaining, firstAmount);

        // now, new ticket with fees, should come first
        credit.mint(address(this), secondAmount);
        credit.approve(address(psm), secondAmount);
        psm.enterExitQueue(secondAmount, secondAmountFee);
        bytes32 secondTicketId = _getTicketId(
            ExitQueuePSM.ExitQueueTicket({
                amountRemaining: secondAmount,
                owner: address(this),
                feePercent: secondAmountFee,
                timestamp: uint64(block.timestamp)
            })
        );

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(psm)), firstAmount + secondAmount);

        (totalCredit, totalCostPegToken) = psm.getTotalCreditInQueue();
        assertEq(totalCredit, firstAmount + secondAmount);
        assertEq(totalCostPegToken, firstPegTokenCost + secondPegTokenCost);
        assertEq(psm.getFirstTicket().amountRemaining, secondAmount);
        assertEq(psm.getQueueLength(), 2);
        assertEq(
            psm.getTicketById(secondTicketId).amountRemaining,
            secondAmount
        );

        // now, new ticket but with now fee, should not change the front
        credit.mint(address(this), thirdAmount);
        credit.approve(address(psm), thirdAmount);
        psm.enterExitQueue(thirdAmount, 0);
        bytes32 thirdTicketId = _getTicketId(
            ExitQueuePSM.ExitQueueTicket({
                amountRemaining: thirdAmount,
                owner: address(this),
                feePercent: 0,
                timestamp: uint64(block.timestamp)
            })
        );

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(
            credit.balanceOf(address(psm)),
            firstAmount + secondAmount + thirdAmount
        );
        (totalCredit, totalCostPegToken) = psm.getTotalCreditInQueue();
        assertEq(totalCredit, firstAmount + secondAmount + thirdAmount);
        assertEq(
            totalCostPegToken,
            firstPegTokenCost + secondPegTokenCost + thirdPegTokenCost
        );
        assertEq(psm.getFirstTicket().amountRemaining, secondAmount);
        assertEq(psm.getQueueLength(), 3);
        assertEq(psm.getTicketById(thirdTicketId).amountRemaining, thirdAmount);
    }

    function testCannotEnterExitQueueWithAmountTooLow() public {
        credit.mint(address(this), 1);
        credit.approve(address(psm), 1);
        vm.expectRevert("ExitQueuePSM: amount too low");
        psm.enterExitQueue(1, 0);
    }

    function testCannotEnterExitQueueWithFeeHigherThan100Pct() public {
        credit.mint(address(this), MIN_AMOUNT);
        credit.approve(address(psm), MIN_AMOUNT);
        vm.expectRevert("ExitQueuePSM: fee should be < 100%");
        psm.enterExitQueue(MIN_AMOUNT, 1e18);
    }

    // test that you cannot create two ticket in the same block (with same timestamp)
    // ensuring it would not make the internal accounting broken
    function testCannotCreateSameTicketTwice() public {
        credit.mint(address(this), 2 * MIN_AMOUNT);
        credit.approve(address(psm), 2 * MIN_AMOUNT);
        psm.enterExitQueue(MIN_AMOUNT, 0);
        vm.expectRevert("ExitQueuePSM: exit queue ticket already saved");
        psm.enterExitQueue(MIN_AMOUNT, 0);
    }

    // test that entering the exit queue with a fee must outbid the front of the queue
    function testEnterExitQueueWithFeeMustOutdiscountHighest() public {
        credit.mint(address(this), 2 * MIN_AMOUNT);
        credit.approve(address(psm), 2 * MIN_AMOUNT);

        // 1. enter the exit queue with 1% fee
        psm.enterExitQueue(MIN_AMOUNT, 0.01e18);

        // 2. try to enter again with 0.1% fee
        vm.expectRevert(
            "ExitQueuePSM: Can only outdiscount current high discounter"
        );
        psm.enterExitQueue(MIN_AMOUNT, 0.001e18);
    }

    // tests that you cannot withdraw before waiting for the withdraw delay
    function testWithdrawTicketFailBeforeWithdrawDelay() public {
        credit.mint(address(this), MIN_AMOUNT);
        credit.approve(address(psm), MIN_AMOUNT);

        // 1. enter the exit queue
        psm.enterExitQueue(MIN_AMOUNT, 0);

        // 2. try to enter again with 0.1% fee
        vm.expectRevert("ExitQueuePSM: withdraw delay not elapsed");
        psm.withdrawTicket(MIN_AMOUNT, 0, block.timestamp);
    }

    // tests you CAN withdraw your ticket after waiting for the withdraw delay
    function testWithdrawTicketWorksAfterDelay() public {
        credit.mint(address(this), MIN_AMOUNT);
        credit.approve(address(psm), MIN_AMOUNT);

        // 1. enter the exit queue
        psm.enterExitQueue(MIN_AMOUNT, 0);
        uint256 enterTimestamp = block.timestamp;

        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(psm)), MIN_AMOUNT);
        assertEq(psm.getQueueLength(), 1);

        // wait 100 blocks
        vm.warp(block.timestamp + (100 * 13));
        vm.roll(block.number + 100);

        // 2. withdraw ticket
        psm.withdrawTicket(MIN_AMOUNT, 0, enterTimestamp);
        assertEq(credit.balanceOf(address(this)), MIN_AMOUNT);
        assertEq(credit.balanceOf(address(psm)), 0);
        // ticket is still in the queue, it's normal
        assertEq(psm.getQueueLength(), 1);

        // cannot withdraw it twice though
        vm.expectRevert("ExitQueuePSM: no amount to withdraw");
        psm.withdrawTicket(MIN_AMOUNT, 0, enterTimestamp);
    }

    // tests that you can mint some CREDIT from the exit queue
    // this tests adds one MIN_AMOUNT ticket to the exit queue
    // and checks that another user can mint "MIN_AMOUNT / 2" credit
    // which will result in the ticket remaining in the exit queue, with its amount remaining
    // being changed. This checks that the user that entered the exit queue received the pegToken
    // and that the total supply of credit did not change (as no new token was minted)
    function testMintWithAvailableTicket() public {
        credit.mint(address(this), MIN_AMOUNT);
        assertEq(credit.totalSupply(), MIN_AMOUNT);
        credit.approve(address(psm), MIN_AMOUNT);

        assertEq(token.balanceOf(address(this)), 0);

        psm.enterExitQueue(MIN_AMOUNT, 0);
        bytes32 ticketId = _getTicketId(
            ExitQueuePSM.ExitQueueTicket({
                amountRemaining: MIN_AMOUNT,
                owner: address(this),
                feePercent: 0,
                timestamp: uint64(block.timestamp)
            })
        );
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(psm)), MIN_AMOUNT);
        assertEq(psm.getQueueLength(), 1);

        uint256 pegTokenAmount = psm.getRedeemAmountOut(MIN_AMOUNT / 2);
        // here the exit queue have MIN_AMOUNT credit, will try to mint MIN_AMOUNT / 2
        address anotherUser = address(456789);
        token.mint(address(anotherUser), pegTokenAmount);
        vm.startPrank(anotherUser);
        token.approve(address(psm), pegTokenAmount);
        psm.mint(anotherUser, pegTokenAmount);
        vm.stopPrank();

        // check that there is still a ticket remaining
        assertEq(psm.getQueueLength(), 1);
        // check that the ticket now holds MIN_AMOUNT/2 credit
        assertEq(psm.getTicketById(ticketId).amountRemaining, MIN_AMOUNT / 2);
        // checks that no new credit have been minted
        assertEq(credit.totalSupply(), MIN_AMOUNT);
        // checks that the user in the queue received the peg token
        assertEq(token.balanceOf(address(this)), pegTokenAmount);
    }

    // same test as before but with an updated credit multiplier
    function testMinWithAvailableTicketWithCreditMultiplier() public {
        _updateCreditMultiplier();
        testMintWithAvailableTicket();
    }

    // tests that a user can mint even if the exit queue does not have enough credit
    // in this test, an exit queue ticket is created, containing MIN_AMOUNT of credit in it
    // and another user tries to mint MIN_AMOUNT + 10k credit. This checks that the user that entered
    // the exit queue received the pegToken for the MIN_AMOUNT of credit and that the remaining (10k) was minted
    // by the PSM. Ensuring the new total supply of CREDIT is now increased by DELTA.
    // also checks that the exit queue is now empty
    // also checks that the user who entered the exit queue with its MIN_AMOUNT ticket cannot withdraw it anymore
    function testMintWithAvailableTicketButNotEnough() public {
        credit.mint(address(this), MIN_AMOUNT);
        assertEq(credit.totalSupply(), MIN_AMOUNT);
        credit.approve(address(psm), MIN_AMOUNT);

        assertEq(token.balanceOf(address(this)), 0);

        psm.enterExitQueue(MIN_AMOUNT, 0);
        uint256 enterTimestamp = block.timestamp;
        bytes32 ticketId = _getTicketId(
            ExitQueuePSM.ExitQueueTicket({
                amountRemaining: MIN_AMOUNT,
                owner: address(this),
                feePercent: 0,
                timestamp: uint64(block.timestamp)
            })
        );
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(psm)), MIN_AMOUNT);
        assertEq(psm.getQueueLength(), 1);

        uint256 delta = 10_000e18;

        uint256 pegTokenAmount = psm.getRedeemAmountOut(MIN_AMOUNT + delta);
        address anotherUser = address(456789);
        token.mint(address(anotherUser), pegTokenAmount);
        vm.startPrank(anotherUser);
        token.approve(address(psm), pegTokenAmount);
        psm.mint(anotherUser, pegTokenAmount);
        vm.stopPrank();

        // check that no ticket remains in the queue
        assertEq(psm.getQueueLength(), 0);
        // check that the ticket now deleted (by testing timestamp to be 0)
        assertEq(psm.getTicketById(ticketId).timestamp, 0);
        // checks that new credit have been minted
        assertEq(credit.totalSupply(), MIN_AMOUNT + delta);
        // checks that the user in the queue received the peg token
        assertEq(
            token.balanceOf(address(this)),
            psm.getRedeemAmountOut(MIN_AMOUNT)
        );

        // check that the ticket cannot be withdrawn because it has been deleted
        // wait 100 blocks
        vm.warp(block.timestamp + (100 * 13));
        vm.roll(block.number + 100);
        vm.expectRevert("ExitQueuePSM: cannot find ticket");
        psm.withdrawTicket(MIN_AMOUNT, 0, enterTimestamp);
    }

    // same test as before but with an updated credit multiplier
    function testMintWithAvailableTicketButNotEnoughWithCreditMultiplier()
        public
    {
        _updateCreditMultiplier();
        testMintWithAvailableTicketButNotEnough();
    }

    // tests that when a user enters the exit queue with a discount (here 10%), then the
    // amount of pegToken used to mint CREDIT is lower than the normal price
    function testMintWithAvailableTicketWithDiscount() public {
        credit.mint(address(this), MIN_AMOUNT);
        assertEq(credit.totalSupply(), MIN_AMOUNT);
        credit.approve(address(psm), MIN_AMOUNT);

        assertEq(token.balanceOf(address(this)), 0);

        // 10% discount
        uint64 fee = 0.1e18;
        psm.enterExitQueue(MIN_AMOUNT, fee);
        bytes32 ticketId = _getTicketId(
            ExitQueuePSM.ExitQueueTicket({
                amountRemaining: MIN_AMOUNT,
                owner: address(this),
                feePercent: fee,
                timestamp: uint64(block.timestamp)
            })
        );
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(psm)), MIN_AMOUNT);
        assertEq(psm.getQueueLength(), 1);

        uint256 pegTokenAmount = psm.getRedeemAmountOut(MIN_AMOUNT / 2);
        // here the exit queue have MIN_AMOUNT credit, will try to mint MIN_AMOUNT / 2
        address anotherUser = address(456789);
        token.mint(address(anotherUser), pegTokenAmount);
        vm.startPrank(anotherUser);
        token.approve(address(psm), pegTokenAmount);
        psm.mint(anotherUser, pegTokenAmount);
        vm.stopPrank();

        // check that there is still a ticket remaining
        assertEq(psm.getQueueLength(), 1);
        // check that the ticket now holds MIN_AMOUNT/2 credit
        assertEq(psm.getTicketById(ticketId).amountRemaining, MIN_AMOUNT / 2);
        // checks that no new credit have been minted
        assertEq(credit.totalSupply(), MIN_AMOUNT);
        // checks that the user in the queue received the peg token for 90% of the value
        assertEq(
            token.balanceOf(address(this)),
            (pegTokenAmount * (1e18 - fee)) / 1e18
        );
    }

    // same test as before but with an updated credit multiplier
    function testMintWithAvailableTicketWithDiscountWithCreditMultiplier()
        public
    {
        _updateCreditMultiplier();
        testMintWithAvailableTicketWithDiscount();
    }

    function _getTicketId(
        ExitQueuePSM.ExitQueueTicket memory ticket
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

    // this function updates the credit multiplier so that it reflects a loss of 12%
    function _updateCreditMultiplier() internal {
        // update creditMultiplier
        credit.mint(address(this), 100e18);
        assertEq(profitManager.creditMultiplier(), 1e18);
        profitManager.notifyPnL(address(this), -12e18, 0); // 12% loss
        assertEq(profitManager.creditMultiplier(), 0.88e18);
        credit.burn(100e18);
    }
}
