// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "@forge-std/Test.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {VoltGovernor} from "@src/governance/VoltGovernor.sol";
import {NameLib as strings} from "@test/utils/NameLib.sol";
import {CoreRoles as roles} from "@src/core/CoreRoles.sol";
import {PostProposalCheck} from "@test/integration/proposal-checks/PostProposalCheck.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {ProtocolConstants as constants} from "@test/utils/ProtocolConstants.sol";

contract IntegrationTestBadDebtFlows is PostProposalCheck {
    function testVoteForSDAIGauge() public {
        /// setup
        vm.prank(addresses.mainnet(strings.TEAM_MULTISIG));
        rateLimitedGuildMinter.mint(address(this), constants.GUILD_SUPPLY); /// mint all of the guild to this contract
        guild.delegate(address(this));

        assertTrue(guild.isGauge(address(term)));
        assertEq(guild.numGauges(), 1);
        assertEq(guild.numLiveGauges(), 1);
    }

    function testAllocateGaugeToSDAI() public {
        testVoteForSDAIGauge();

        guild.incrementGauge(address(term), constants.GUILD_SUPPLY);

        assertEq(guild.totalWeight(), constants.GUILD_SUPPLY);
        assertTrue(guild.isUserGauge(address(this), address(term)));
    }

    function _supplyCollateralUserOne(
        uint256 borrowAmount,
        uint128 supplyAmount
    ) public returns (bytes32 loanId) {
        deal(address(sdai), userOne, supplyAmount);

        vm.startPrank(userOne);
        sdai.approve(address(term), supplyAmount);
        loanId = term.borrow(borrowAmount, supplyAmount);
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), borrowAmount, "incorrect loan debt");
        assertEq(
            sdai.balanceOf(address(term)),
            supplyAmount,
            "sdai balance of term incorrect"
        );
        assertEq(
            credit.totalSupply(),
            borrowAmount + constants.CREDIT_SUPPLY,
            "incorrect credit supply"
        );
        assertEq(
            credit.balanceOf(userOne),
            borrowAmount,
            "incorrect credit balance"
        );
        assertEq(
            rateLimitedCreditMinter.buffer(),
            constants.CREDIT_HARDCAP - constants.CREDIT_SUPPLY - borrowAmount,
            "incorrect buffer"
        );
        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            block.timestamp,
            "incorrect last buffer used time"
        );
        assertEq(term.issuance(), borrowAmount, "incorrect supply issuance");
    }

    function testRepayLoan(
        uint128 supplyAmount,
        uint128 borrowAmount,
        uint32 warpAmount
    ) public {
        testAllocateGaugeToSDAI(); /// setup
        supplyAmount = uint128(
            _bound(
                uint256(supplyAmount),
                term.MIN_BORROW(),
                type(uint128).max /// you can supply up to this amount
            )
        );
        
        borrowAmount = uint128(
            _bound(
                uint256(borrowAmount),
                term.MIN_BORROW(),
                Math.min(
                    constants.CREDIT_HARDCAP - constants.CREDIT_SUPPLY,
                    supplyAmount
                ) /// lesser of the two, cannot borrow more than supply amt or buffer
            )
        );

        warpAmount = uint32(_bound(uint256(warpAmount), 1, 10 * 365 days)); /// bound from 1 second to 10 year warp

        bytes32 loanId = _supplyCollateralUserOne(borrowAmount, supplyAmount);
        vm.warp(block.timestamp + warpAmount);
        vm.roll(block.number + warpAmount / 12); /// roll the amt of blocks that would have passed on mainnet

        uint256 profit = term.getLoanDebt(loanId) - borrowAmount;

        uint256 amountMinted = _doMint(
            userTwo,
            uint128(term.getLoanDebt(loanId) / 1e12 + 1)
        );

        console.log("warpAmount: ", warpAmount);
        console.log("borrowAmount: ", borrowAmount);
        console.log("supplyAmount: ", supplyAmount);
        console.log("erc20TotalSupply: ", credit.erc20TotalSupply());
        console.log("pendingRebaseRewards: ", credit.pendingRebaseRewards());
        console.log("user one starting credit balance:: ", credit.balanceOf(userOne));
        
        vm.startPrank(userTwo);
        credit.approve(address(term), term.getLoanDebt(loanId));
        term.repay(loanId);
        credit.burn(credit.balanceOf(userTwo));
        vm.stopPrank();


        console.log("user one credit balance after repay:: ", credit.balanceOf(userOne));
        
        assertEq(term.getLoanDebt(loanId), 0, "incorrect loan debt");

        assertEq(
            credit.balanceOf(userOne),
            borrowAmount,
            "incorrect userOne credit balance"
        );
        assertEq(
            sdai.balanceOf(address(term)),
            0,
            "sdai balance of term incorrect"
        );
        uint256 expectedProfit = (profit * 9) % 10 == 0
            ? (profit * 9) / 10
            : (profit * 9) / 10 + 1;

        /// total supply should equal
        // amountMinted + expectedProfit

        console.log("profit: ", profit);
        console.log("amountMinted: ", amountMinted);
        console.log("expectedProfit: ", expectedProfit);
        console.log("erc20TotalSupply: ", credit.erc20TotalSupply());
        console.log("pendingRebaseRewards: ", credit.pendingRebaseRewards());

        assertEq(
            credit.totalSupply(),
            constants.CREDIT_SUPPLY + borrowAmount + expectedProfit,
            "incorrect credit supply"
        );
        assertEq(credit.balanceOf(userOne), 0, "incorrect credit balance");
        assertEq(
            rateLimitedCreditMinter.buffer(),
            constants.CREDIT_HARDCAP - constants.CREDIT_SUPPLY,
            "incorrect buffer"
        );
        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            block.timestamp,
            "incorrect last buffer used time"
        );
        assertEq(term.issuance(), 0, "incorrect issuance, should be 0");
    }

    function testTermOffboarding() public {
        if (guild.balanceOf(address(this)) == 0) {
            testVoteForSDAIGauge();
        }

        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 1);

        offboarder.proposeOffboard(address(term));
        vm.roll(block.number + 1);
        offboarder.supportOffboard(block.number - 1, address(term));
        offboarder.offboard(address(term));

        assertFalse(guild.isGauge(address(term)));
    }

    function _psmMint(uint128 amount) public {
        /// mint CREDIT between .01 USDC and buffer capacity
        amount = uint128(
            _bound(amount, 0.01e6, rateLimitedCreditMinter.buffer() / 1e12)
        );

        _doMint(userTwo, amount);
    }

    function _doMint(address to, uint128 amount) private returns (uint256) {
        deal(address(usdc), to, amount);

        uint256 startingUsdcBalance = usdc.balanceOf(to);
        uint256 startingCreditBalance = credit.balanceOf(to);

        vm.startPrank(to);
        usdc.approve(address(psm), amount);
        uint256 amountOut = psm.mint(to, amount);
        vm.stopPrank();

        uint256 endingUsdcBalance = usdc.balanceOf(to);
        uint256 endingCreditBalance = credit.balanceOf(to);

        assertEq(
            startingCreditBalance + amountOut,
            endingCreditBalance,
            "incorrect credit balance"
        );
        assertEq(
            startingUsdcBalance - amount,
            endingUsdcBalance,
            "incorrect usdc balance"
        );

        return amountOut;
    }
}
