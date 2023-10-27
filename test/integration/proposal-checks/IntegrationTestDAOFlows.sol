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
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {PostProposalCheckFixture} from "@test/integration/proposal-checks/PostProposalCheckFixture.sol";
import {DeploymentConstants as constants} from "@test/utils/DeploymentConstants.sol";

contract IntegrationTestDAOFlows is PostProposalCheckFixture {
    function setUp() public override {
        super.setUp();

        uint256 mintAmount = governor.quorum(0);

        vm.prank(addresses.mainnet(strings.TEAM_MULTISIG));
        rateLimitedGuildMinter.mint(address(this), mintAmount); /// mint quorum to contract

        guild.delegate(address(this));

        vm.roll(block.number + 1); /// ensure user votes register

        /// new term so that onboard succeeds
        term = LendingTerm(
            onboarder.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: addresses.mainnet(strings.ERC20_SDAI),
                    maxDebtPerCollateralToken: constants.MAX_SDAI_CREDIT_RATIO,
                    interestRate: constants.SDAI_RATE,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: constants.SDAI_CREDIT_HARDCAP
                })
            )
        );
    }

    function testProposeOnboardingInGovernorDao()
        public
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        )
    {
        (targets, values, calldatas, description) = onboarder
            .getOnboardProposeArgs(address(term));

        proposalId = governor.propose(targets, values, calldatas, description);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Pending)
        );
    }

    function testCanCastVoteAndQueue()
        public
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        )
    {
        /// have onboarder generate calldata
        (
            proposalId,
            targets,
            values,
            calldatas,
            description
        ) = testProposeOnboardingInGovernorDao();

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Pending)
        );

        vm.roll(block.number + constants.VOTING_PERIOD - 1);
        vm.warp(block.timestamp + governor.proposalDeadline(proposalId) - 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + constants.VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );
    }

    function testOnboardingGovernorDao() public {
        /// have onboarder generate calldata
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = testCanCastVoteAndQueue();

        // execute
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + constants.TIMELOCK_DELAY + 13);
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(governor.state(proposalId)),
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

    function testVetoDaoBlocksOnboarding() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = testCanCastVoteAndQueue();

        uint256 queueTime = block.timestamp;
        bytes32 timelockId = timelock.hashOperationBatch(
            targets,
            values,
            calldatas,
            bytes32(0),
            keccak256(bytes(description))
        );

        deal(
            addresses.mainnet(strings.CREDIT_TOKEN),
            address(this),
            vetoGovernor.quorum(0)
        );

        credit.delegate(address(this)); /// delegate to self

        /// register votes
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        /// veto
        uint256 vetoId = vetoGovernor.createVeto(timelockId);

        /// voting starts
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "volt governor: proposal not queued"
        );
        assertEq(
            uint8(vetoGovernor.state(vetoId)),
            uint8(IGovernor.ProposalState.Active),
            "veto governor: proposal not active"
        );

        vetoGovernor.castVote(
            vetoId,
            uint8(GovernorCountingSimple.VoteType.Against)
        );

        assertEq(
            uint8(vetoGovernor.state(vetoId)),
            uint8(IGovernor.ProposalState.Succeeded),
            "proposal not defeated"
        );

        assertTrue(timelock.isOperation(timelockId), "incorrect operation");
        assertEq(
            timelock.getTimestamp(timelockId),
            queueTime + timelock.getMinDelay(),
            "incorrect queue time"
        );
        assertFalse(timelock.isOperationDone(timelockId), "operation done");
        assertFalse(timelock.isOperationReady(timelockId), "operation ready");
        assertTrue(
            timelock.isOperationPending(timelockId),
            "operation not pending"
        );

        vetoGovernor.executeVeto(timelockId);

        /// validate timelock action is cancelled

        assertFalse(timelock.isOperation(timelockId));
        assertEq(timelock.getTimestamp(timelockId), 0);
        assertFalse(timelock.isOperationDone(timelockId));
        assertFalse(timelock.isOperationReady(timelockId));
        assertFalse(timelock.isOperationPending(timelockId));

        assertEq(
            uint8(governor.state(proposalId)), /// calls into timelock, sees operation doesn't exist, returns canceled
            uint8(IGovernor.ProposalState.Canceled),
            "proposal not canceled"
        );

        vm.expectRevert("Governor: proposal not successful");
        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
    }

    /// todo add team multisig cancelling

    function testTeamMultisigCancels() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = testCanCastVoteAndQueue();

        uint256 queueTime = block.timestamp;
        bytes32 timelockId = timelock.hashOperationBatch(
            targets,
            values,
            calldatas,
            bytes32(0),
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "volt governor: proposal not queued"
        );

        assertTrue(timelock.isOperation(timelockId), "incorrect operation");
        assertEq(
            timelock.getTimestamp(timelockId),
            queueTime + timelock.getMinDelay(),
            "incorrect queue time"
        );
        assertFalse(timelock.isOperationDone(timelockId), "operation done");
        assertFalse(timelock.isOperationReady(timelockId), "operation ready");
        assertTrue(
            timelock.isOperationPending(timelockId),
            "operation not pending"
        );

        vm.startPrank(addresses.mainnet(strings.TEAM_MULTISIG));
        governor.guardianCancel(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        vm.stopPrank();

        /// validate timelock action is cancelled

        assertFalse(timelock.isOperation(timelockId));
        assertEq(timelock.getTimestamp(timelockId), 0);
        assertFalse(timelock.isOperationDone(timelockId));
        assertFalse(timelock.isOperationReady(timelockId));
        assertFalse(timelock.isOperationPending(timelockId));

        assertEq(
            uint8(governor.state(proposalId)), /// calls into timelock, sees operation doesn't exist, returns canceled
            uint8(IGovernor.ProposalState.Canceled),
            "proposal not canceled"
        );

        vm.expectRevert("Governor: proposal not successful");
        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
    }
}
