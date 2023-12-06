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

contract IntegrationTestOnboardOffboard is PostProposalCheckFixture {
    function setUp() public override {
        super.setUp();
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

        vm.prank(AddressLib.get("DAO_TIMELOCK"));
        guild.enableTransfer();

        uint256 mintAmount = onboarder.quorum(0);
        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(address(this), mintAmount); /// mint all of the guild to this contract
        guild.delegate(address(this));
        vm.roll(block.number + 1); /// ensure user votes register
    }

    function testGuildTokenTransferEnabled() public {
        assertTrue(guild.transferable());
    }

    function testCoreCorrectlySetOnLendingTermLogic() public {
        assertEq(
            address(LendingTerm(AddressLib.get("LENDING_TERM_V1")).core()),
            address(1)
        );
    }

    function testOnboarding() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = onboarder.getOnboardProposeArgs(address(term));
        uint256 proposalId = onboarder.proposeOnboard(address(term));

        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Pending)
        );

        vm.roll(block.number + onboarder.votingPeriod() - 1);
        vm.warp(block.timestamp + onboarder.proposalDeadline(proposalId) - 1);

        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        onboarder.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + onboarder.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        onboarder.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );

        // execute
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );

        onboarder.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed)
        );

        _roleValidation();

        assertTrue(guild.isGauge(address(term)));
    }

    function _roleValidation() private {
        /// role validation
        assertTrue(core.hasRole(roles.GAUGE_PNL_NOTIFIER, address(term)));
        assertTrue(
            core.hasRole(roles.RATE_LIMITED_CREDIT_MINTER, address(term))
        );
    }

    function testOffboarding() public {
        testOnboarding();

        uint256 startingBlockNumber = block.number;
        offboarder.proposeOffboard(address(term));

        _roleValidation();

        vm.roll(block.number + 1);

        offboarder.supportOffboard(startingBlockNumber, address(term));

        _roleValidation();

        assertTrue(offboarder.canOffboard(address(term)));

        assertTrue(guild.isGauge(address(term)));

        offboarder.offboard(address(term));

        assertFalse(guild.isGauge(address(term)));

        _roleValidation();

        offboarder.cleanup(address(term));

        assertFalse(core.hasRole(roles.GAUGE_PNL_NOTIFIER, address(term)));
        assertFalse(
            core.hasRole(roles.RATE_LIMITED_CREDIT_MINTER, address(term))
        );

        /// assert that term borrowable amount is 0
        assertEq(guild.calculateGaugeAllocation(address(term), 100_000_000), 0);
    }

    /// This test will pass once a nonce is added to onboarder
    function testOnboardOffBoardOnboard() public {
        testOnboarding();

        vm.warp(block.timestamp + onboarder.MIN_DELAY_BETWEEN_PROPOSALS() + 1);

        /// offboarding flow

        uint256 startingBlockNumber = block.number;
        offboarder.proposeOffboard(address(term));

        _roleValidation();

        vm.roll(block.number + 1);

        offboarder.supportOffboard(startingBlockNumber, address(term));

        _roleValidation();

        assertTrue(offboarder.canOffboard(address(term)));

        assertTrue(guild.isGauge(address(term)));

        offboarder.offboard(address(term));

        assertFalse(guild.isGauge(address(term)));

        _roleValidation();

        /// do not cleanup

        /// now onboard again
        testOnboarding();

        /// try to cleanup, and fail

        vm.expectRevert("LendingTermOffboarding: re-onboarded");
        offboarder.cleanup(address(term));

        /// offboard again as offboard vote already passed before but did not finalize
        assertTrue(guild.isGauge(address(term)));

        offboarder.offboard(address(term));

        assertTrue(offboarder.canOffboard(address(term)));
        assertFalse(guild.isGauge(address(term)));
        offboarder.cleanup(address(term));

        assertFalse(offboarder.canOffboard(address(term)));

        assertFalse(core.hasRole(roles.GAUGE_PNL_NOTIFIER, address(term)));
        assertFalse(
            core.hasRole(roles.RATE_LIMITED_CREDIT_MINTER, address(term))
        );

        /// assert that term borrowable amount is 0
        assertEq(guild.calculateGaugeAllocation(address(term), 100_000_000), 0);
    }
}
