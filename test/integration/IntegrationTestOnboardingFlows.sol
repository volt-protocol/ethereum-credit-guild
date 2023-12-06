// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "@forge-std/Test.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {AddressLib} from "@test/proposals/AddressLib.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {CoreRoles as roles} from "@src/core/CoreRoles.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestOnboardingFlows is PostProposalCheckFixture {
    function setUp() public override {
        super.setUp();

        uint256 mintAmount = governor.quorum(0);

        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(address(this), mintAmount); /// mint quorum to contract

        guild.delegate(address(this));

        vm.roll(block.number + 1); /// ensure user votes register
    }

    function testCreateNewTerm() public {
        /// new term so that onboard succeeds
        term = LendingTerm(
            onboarder.createTerm(
                AddressLib.get("LENDING_TERM_V1"),
                LendingTerm.LendingTermParams({
                    collateralToken: AddressLib.get("ERC20_SDAI"),
                    maxDebtPerCollateralToken: 1e18,
                    interestRate: 0.04e18,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: rateLimitedCreditMinter.buffer()
                })
            )
        );

        uint256 contractSize;
        address termAddress = address(term);

        assembly {
            contractSize := extcodesize(termAddress)
        }

        assertEq(contractSize, 45, "clone size of term should be 45 bytes");
    }

    function testProposeFails() public {
        vm.expectRevert(
            "LendingTermOnboarding: cannot propose arbitrary actions"
        );
        onboarder.propose(
            new address[](0),
            new uint256[](0),
            new bytes[](0),
            ""
        );
    }

    function testProposeOnboardFailsInvalidTerm() public {
        vm.expectRevert("LendingTermOnboarding: invalid term");
        onboarder.proposeOnboard(address(0));
    }
}
