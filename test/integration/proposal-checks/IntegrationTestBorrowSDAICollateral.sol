// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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

contract IntegrationTestBorrowAgainstSDAICollateral is PostProposalCheck {
    function testTermParamSetup() public {
        assertEq(term.collateralToken(), address(sdai));
        LendingTerm.LendingTermParams memory params = term.getParameters();
        assertEq(params.collateralToken, address(sdai));
        assertEq(params.openingFee, 0);
        assertEq(params.interestRate, constants.SDAI_RATE);
        assertEq(params.minPartialRepayPercent, 0);
        assertEq(params.maxDelayBetweenPartialRepay, 0);
        assertEq(
            params.maxDebtPerCollateralToken,
            constants.MAX_SDAI_CREDIT_RATIO
        );
    }

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

    function testSupplyCollateralUserOne(uint128 supplyAmount) public returns (bytes32 loanId) {
        supplyAmount = uint128(
            _bound(
                uint256(supplyAmount),
                term.MIN_BORROW(),
                constants.CREDIT_HARDCAP - constants.CREDIT_SUPPLY
            )
        );

        testAllocateGaugeToSDAI();

        deal(address(sdai), userOne, supplyAmount);

        vm.startPrank(userOne);
        sdai.approve(address(term), supplyAmount);
        loanId = term.borrow(supplyAmount, supplyAmount);
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), supplyAmount, "incorrect loan debt");
        assertEq(
            sdai.balanceOf(address(term)),
            supplyAmount,
            "sdai balance of term incorrect"
        );
        assertEq(
            credit.totalSupply(),
            supplyAmount + constants.CREDIT_SUPPLY,
            "incorrect credit supply"
        );
        assertEq(
            credit.balanceOf(userOne),
            supplyAmount,
            "incorrect credit balance"
        );
        assertEq(
            rateLimitedCreditMinter.buffer(),
            constants.CREDIT_HARDCAP - constants.CREDIT_SUPPLY - supplyAmount,
            "incorrect buffer"
        );
        assertEq(
            rateLimitedCreditMinter.lastBufferUsedTime(),
            block.timestamp,
            "incorrect last buffer used time"
        );
    }

    function testRepayLoan(uint128 supplyAmount) public {
        bytes32 loanId = testSupplyCollateralUserOne(supplyAmount);
        vm.warp(block.timestamp + 1);

        /// account for accrued interest
        deal(address(credit), userOne, term.getLoanDebt(loanId));

        vm.startPrank(userOne);
        credit.approve(address(term), term.getLoanDebt(loanId));
        term.repay(loanId);
        vm.stopPrank();

        assertEq(term.getLoanDebt(loanId), 0, "incorrect loan debt");

        assertEq(
            sdai.balanceOf(address(term)),
            0,
            "sdai balance of term incorrect"
        );
        assertEq(
            credit.totalSupply(),
            constants.CREDIT_SUPPLY,
            "incorrect credit supply"
        );
        assertEq(
            credit.balanceOf(userOne),
            0,
            "incorrect credit balance"
        );
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
    }
}
