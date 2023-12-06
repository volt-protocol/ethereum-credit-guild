// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "@forge-std/Test.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {AddressLib} from "@test/proposals/AddressLib.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {GuildVetoGovernor} from "@src/governance/GuildVetoGovernor.sol";
import {CoreRoles as roles} from "@src/core/CoreRoles.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestDAOFlows is PostProposalCheckFixture {
    function setUp() public override {
        super.setUp();

        uint256 mintAmount = governor.quorum(0);

        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(address(this), mintAmount); /// mint quorum to contract

        guild.delegate(address(this));

        vm.roll(block.number + 1); /// ensure user votes register

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

        vm.roll(block.number + governor.votingPeriod() - 1);
        vm.warp(block.timestamp + governor.proposalDeadline(proposalId) - 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
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
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

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

        GuildVetoGovernor veto = GuildVetoGovernor(
            payable(AddressLib.get("DAO_VETO_GUILD"))
        );
        assertEq(
            address(veto.timelock()),
            address(timelock),
            "timelock mismatch"
        );

        uint256 queueTime = block.timestamp;
        bytes32 timelockId = timelock.hashOperationBatch(
            targets,
            values,
            calldatas,
            bytes32(0),
            keccak256(bytes(description))
        );

        deal(address(credit), address(this), veto.quorum(0));

        credit.delegate(address(this)); /// delegate to self

        /// register votes
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        /// veto
        uint256 vetoId = veto.createVeto(timelockId);

        /// voting starts
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "ecg governor: proposal not queued"
        );
        assertEq(
            uint8(veto.state(vetoId)),
            uint8(IGovernor.ProposalState.Active),
            "ecg governor: proposal not active"
        );

        veto.castVote(vetoId, uint8(GovernorCountingSimple.VoteType.Against));

        assertEq(
            uint8(veto.state(vetoId)),
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

        veto.executeVeto(timelockId);

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
            "ecg governor: proposal not queued"
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

        vm.startPrank(teamMultisig);
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

    /// ----------------- Governor DAO Actions -------------------
    function testUpdateVotingDelay() public {
        uint256 newVotingDelay = 1 days;

        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            governor.setVotingDelay.selector,
            newVotingDelay
        );

        string memory description = "Update voting delay to 1 day";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed),
            "proposal not executed"
        );

        assertEq(governor.votingDelay(), newVotingDelay);
    }

    function testSetVotingPeriod() public {
        uint256 newVotingPeriod = 1 days;

        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            governor.setVotingPeriod.selector,
            newVotingPeriod
        );

        string memory description = "Update voting period to 1 day";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed),
            "proposal not executed"
        );

        assertEq(governor.votingPeriod(), newVotingPeriod);
    }

    function testSetProposalThreshold() public {
        uint256 newProposalThreshold = 1_000_000 * 1e18;

        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            governor.setProposalThreshold.selector,
            newProposalThreshold
        );

        string memory description = "Update voting period to 1 day";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed),
            "proposal not executed"
        );

        assertEq(governor.proposalThreshold(), newProposalThreshold);

        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(userOne, newProposalThreshold); /// mint quorum amount to user one

        vm.startPrank(userOne);
        guild.delegate(userOne);

        vm.roll(block.number + 1);
        description = "Can now propose with just 1m guild tokens";

        proposalId = governor.propose(targets, values, calldatas, description);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );
    }

    function testSetQuorum() public {
        uint256 newQuorum = 100_000_000 * 1e18;

        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            governor.setQuorum.selector,
            newQuorum
        );

        string memory description = "Update quourum to 100m guild";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed),
            "proposal not executed"
        );

        assertEq(governor.quorum(0), newQuorum, "new quorum not set");

        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(userOne, newQuorum); /// mint new quorum amount to user one

        vm.startPrank(userOne);
        guild.delegate(userOne);

        vm.roll(block.number + 1);
        description = "Can now pass with 100m guild tokens";

        proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.stopPrank();
    }

    function testCreateNewCoreRole() public {
        bytes32 newRole = keccak256("NEW_ROLE");

        address[] memory targets = new address[](2);
        targets[0] = address(core);
        targets[1] = address(core);

        uint256[] memory values = new uint256[](2); /// leave empty to no value is sent

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(
            core.createRole.selector,
            newRole,
            roles.GOVERNOR
        );
        calldatas[1] = abi.encodeWithSelector(
            core.grantRole.selector,
            newRole,
            address(this)
        );

        string
            memory description = "Create NEW_ROLE that governor can grant and revoke, grant to this address";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed),
            "proposal not executed"
        );

        assertEq(
            core.getRoleAdmin(newRole),
            roles.GOVERNOR,
            "new role not created"
        );

        assertTrue(
            core.hasRole(newRole, address(this)),
            "new role not granted properly"
        );
    }

    function testMultisigCannotSetQuorum() public {
        uint256 newQuorum = 20_000_000 * 1e18;
        vm.prank(teamMultisig);
        vm.expectRevert("UNAUTHORIZED");
        governor.setQuorum(newQuorum);
    }

    function testMultisigCannotSetProposalThreshold() public {
        uint256 newProposalThreshold = 2_000_000 * 1e18;

        vm.prank(teamMultisig);
        vm.expectRevert("UNAUTHORIZED");
        governor.setProposalThreshold(newProposalThreshold);
    }

    function testMultisigCannotSetVotingDelay() public {
        uint256 newVotingDelay = 2 days / 12; /// convert time to block numbers

        vm.prank(teamMultisig);
        vm.expectRevert("UNAUTHORIZED");
        governor.setVotingDelay(newVotingDelay);
    }

    function testMultisigCannotSetVotingPeriod() public {
        uint256 newVotingPeriod = 8 days / 12; /// convert time to block numbers

        vm.prank(teamMultisig);
        vm.expectRevert("UNAUTHORIZED");
        governor.setVotingPeriod(newVotingPeriod);
    }

    function testSupportsCancelOrProposalSelctor() public {
        assertTrue(
            governor.supportsInterface(
                governor.cancel.selector ^ governor.proposalProposer.selector
            ),
            "governor does not support cancel/proposer selectors"
        );
        assertTrue(
            governor.supportsInterface(type(IERC1155Receiver).interfaceId),
            "governor does not support ERC1155 receiver selectors"
        );
    }

    /// Offboarding setting quorum

    function testSetOffboardingQuorum() public {
        uint256 newQuorum = 100_000_000 * 1e18;

        address[] memory targets = new address[](1);
        targets[0] = address(offboarder);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            offboarder.setQuorum.selector,
            newQuorum
        );

        string memory description = "Update offboarding quourum to 100m guild";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed),
            "proposal not executed"
        );

        assertEq(
            offboarder.quorum(),
            newQuorum,
            "new quorum not set in offboarder"
        );
    }

    function testSetvetoGuildGovernorQuorum() public {
        uint256 newQuorum = 100_000_000 * 1e18;

        address[] memory targets = new address[](1);
        targets[0] = address(vetoGuildGovernor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            vetoGuildGovernor.setQuorum.selector,
            newQuorum
        );

        string
            memory description = "Update veto governor quourum to 100m credit";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed),
            "proposal not executed"
        );

        assertEq(
            vetoGuildGovernor.quorum(0),
            newQuorum,
            "new quorum not set in offboarder"
        );
    }
}
