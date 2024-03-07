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
}
