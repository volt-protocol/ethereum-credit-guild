// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";

contract GuildGovernorUnitTest is Test {
    address private governorAddress = address(1);
    address private guardianAddress = address(2);
    Core private core;
    MockERC20 private token;
    GuildTimelockController private timelock;
    GuildGovernor private governor;

    uint256 private constant _TIMELOCK_MIN_DELAY = 12345;
    uint256 private constant _VOTING_DELAY = 0;
    uint256 private constant _VOTING_PERIOD = 100_000; // ~14 days
    uint256 private constant _PROPOSAL_THRESHOLD = 2_500_000e18;
    uint256 private constant _QUORUM = 20_000_000e18;

    uint256 __lastCallValue = 0;

    function __dummyCall(uint256 val) external {
        __lastCallValue = val;
    }

    receive() external payable {} // make this contract able to receive ETH

    function setUp() public {
        // vm state needs a coherent timestamp & block for timelock logic
        vm.warp(1677869014);
        vm.roll(16749838);

        // create contracts
        core = new Core();
        core.grantRole(CoreRoles.GOVERNOR, governorAddress);
        core.grantRole(CoreRoles.GUARDIAN, guardianAddress);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        token = new MockERC20();
        timelock = new GuildTimelockController(
            address(core),
            _TIMELOCK_MIN_DELAY
        );
        governor = new GuildGovernor(
            address(core),
            address(timelock),
            address(token),
            _VOTING_DELAY,
            _VOTING_PERIOD,
            _PROPOSAL_THRESHOLD,
            _QUORUM
        );

        // grant role
        vm.startPrank(governorAddress);
        core.createRole(CoreRoles.TIMELOCK_EXECUTOR, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.TIMELOCK_EXECUTOR, address(0));
        core.createRole(CoreRoles.TIMELOCK_CANCELLER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.TIMELOCK_CANCELLER, guardianAddress);
        core.createRole(CoreRoles.TIMELOCK_PROPOSER, CoreRoles.GOVERNOR);
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, address(governor));
        vm.stopPrank();
    }

    function testPublicGetters() public {
        assertEq(governor.timelock(), address(timelock));
        assertEq(governor.votingDelay(), _VOTING_DELAY);
        assertEq(governor.votingPeriod(), _VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), _PROPOSAL_THRESHOLD);
        assertEq(governor.quorum(0), _QUORUM);
        assertEq(governor.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        assertEq(address(governor.token()), address(token));
        assertEq(governor.name(), "ECG Governor");
        assertEq(governor.version(), "1");
    }

    function testSuccessfulProposal() public {
        // proposal calls
        address[] memory targets = new address[](1);
        targets[0] = address(this);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(
            GuildGovernorUnitTest.__dummyCall.selector,
            12345
        );

        // propose a new vote
        token.mockSetVotes(address(this), _QUORUM);
        uint256 proposalId = governor.propose(
            targets,
            values,
            payloads,
            "Vote for 12345"
        );
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Pending)
        );
        assertEq(
            uint256(governor.proposalSnapshot(proposalId)),
            block.number + _VOTING_DELAY
        );
        assertEq(
            uint256(governor.proposalDeadline(proposalId)),
            block.number + _VOTING_PERIOD
        );

        // on next block, the vote is active
        vm.roll(block.number + _VOTING_DELAY + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Active)
        );

        // vote in support
        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );
        assertEq(governor.hasVoted(proposalId, address(this)), true); // we have voted
        (
            uint256 againstVotes,
            uint256 forVotes,
            uint256 abstainVotes
        ) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, _QUORUM); // we voted and reached quorum
        assertEq(abstainVotes, 0);

        // queue
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded)
        );
        governor.queue(targets, values, payloads, keccak256("Vote for 12345"));
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued)
        );

        // action is in the timelock
        bytes32 timelockId = timelock.hashOperationBatch(
            targets,
            values,
            payloads,
            bytes32(0),
            keccak256("Vote for 12345")
        );
        assertEq(timelock.isOperationPending(timelockId), true);
        assertEq(timelock.isOperationReady(timelockId), false);
        assertEq(timelock.isOperationDone(timelockId), false);

        // forward in time, execute
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 1);
        assertEq(timelock.isOperationPending(timelockId), true);
        assertEq(timelock.isOperationReady(timelockId), true);
        assertEq(timelock.isOperationDone(timelockId), false);
        governor.execute(
            targets,
            values,
            payloads,
            keccak256("Vote for 12345")
        );
        assertEq(timelock.isOperationPending(timelockId), false);
        assertEq(timelock.isOperationReady(timelockId), false);
        assertEq(timelock.isOperationDone(timelockId), true);
        assertEq(__lastCallValue, 12345);
    }

    function testDefeatedProposal() public {
        // proposal calls
        address[] memory targets = new address[](1);
        targets[0] = address(this);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(
            GuildGovernorUnitTest.__dummyCall.selector,
            12345
        );

        // propose a new vote
        address voter1 = address(1);
        address voter2 = address(2);
        token.mockSetVotes(voter1, _QUORUM);
        token.mockSetVotes(voter2, _QUORUM + 1);
        vm.prank(voter1);
        uint256 proposalId = governor.propose(
            targets,
            values,
            payloads,
            "Vote for 12345"
        );
        vm.roll(block.number + _VOTING_DELAY + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Active)
        );

        // vote in support
        vm.prank(voter1);
        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );
        // vote against
        vm.prank(voter2);
        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.Against)
        );

        // after vote period is over, status = Defeated because Against > For
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated)
        );
    }

    function testQuorumNotReached() public {
        // proposal calls
        address[] memory targets = new address[](1);
        targets[0] = address(this);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(
            GuildGovernorUnitTest.__dummyCall.selector,
            12345
        );

        // propose a new vote
        address voter1 = address(1);
        address voter2 = address(2);
        token.mockSetVotes(voter1, _QUORUM / 2 - 1);
        token.mockSetVotes(voter2, _QUORUM / 2 - 1);
        vm.prank(voter1);
        uint256 proposalId = governor.propose(
            targets,
            values,
            payloads,
            "Vote for 12345"
        );
        vm.roll(block.number + _VOTING_DELAY + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Active)
        );

        // vote in support
        vm.prank(voter1);
        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );
        // vote abstain
        vm.prank(voter2);
        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.Abstain)
        );

        // after vote period is over, status = Defeated because quorum is not reached
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated)
        );
    }

    function testGuardianCancelVote() public {
        // proposal calls
        address[] memory targets = new address[](1);
        targets[0] = address(this);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(
            GuildGovernorUnitTest.__dummyCall.selector,
            12345
        );

        // propose a new vote
        address voter1 = address(1);
        address voter2 = address(2);
        token.mockSetVotes(voter1, _QUORUM / 2 - 1);
        token.mockSetVotes(voter2, _QUORUM / 2 - 1);
        vm.prank(voter1);
        uint256 proposalId = governor.propose(
            targets,
            values,
            payloads,
            "Vote for 12345"
        );
        vm.roll(block.number + _VOTING_DELAY + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Active)
        );

        // guardian cancel
        vm.prank(guardianAddress);
        governor.guardianCancel(targets, values, payloads, keccak256("Vote for 12345"));
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Canceled)
        );
    }

    function testProposerCancelVote() public {
        // proposal calls
        address[] memory targets = new address[](1);
        targets[0] = address(this);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(
            GuildGovernorUnitTest.__dummyCall.selector,
            12345
        );

        // propose a new vote
        address voter1 = address(1);
        address voter2 = address(2);
        token.mockSetVotes(voter1, _QUORUM / 2 - 1);
        token.mockSetVotes(voter2, _QUORUM / 2 - 1);
        vm.prank(voter1);
        uint256 proposalId = governor.propose(
            targets,
            values,
            payloads,
            "Vote for 12345"
        );

        // proposer cancel
        vm.prank(voter1);
        governor.cancel(targets, values, payloads, keccak256("Vote for 12345"));
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Canceled)
        );
    }

    function testTimelockCancelAction() public {
        // proposal calls
        address[] memory targets = new address[](1);
        targets[0] = address(this);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(
            GuildGovernorUnitTest.__dummyCall.selector,
            12345
        );

        // propose a new vote
        token.mockSetVotes(address(this), _QUORUM);
        uint256 proposalId = governor.propose(
            targets,
            values,
            payloads,
            "Vote for 12345"
        );
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Pending)
        );
        assertEq(
            uint256(governor.proposalSnapshot(proposalId)),
            block.number + _VOTING_DELAY
        );
        assertEq(
            uint256(governor.proposalDeadline(proposalId)),
            block.number + _VOTING_PERIOD
        );

        // on next block, the vote is active
        vm.roll(block.number + _VOTING_DELAY + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Active)
        );

        // vote in support
        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );
        assertEq(governor.hasVoted(proposalId, address(this)), true); // we have voted
        (
            uint256 againstVotes,
            uint256 forVotes,
            uint256 abstainVotes
        ) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, _QUORUM); // we voted and reached quorum
        assertEq(abstainVotes, 0);

        // queue
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 10);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded)
        );
        governor.queue(targets, values, payloads, keccak256("Vote for 12345"));
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued)
        );

        // action is in the timelock
        bytes32 timelockId = timelock.hashOperationBatch(
            targets,
            values,
            payloads,
            bytes32(0),
            keccak256("Vote for 12345")
        );
        assertEq(timelock.isOperationPending(timelockId), true);
        assertEq(timelock.isOperationReady(timelockId), false);
        assertEq(timelock.isOperationDone(timelockId), false);

        // cancel in timelock
        vm.prank(guardianAddress);
        timelock.cancel(timelockId);

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Canceled)
        );
    }

    function testSetVotingDelay() public {
        vm.expectRevert("UNAUTHORIZED");
        governor.setVotingDelay(12);

        vm.prank(governorAddress);
        governor.setVotingDelay(34);
        assertEq(governor.votingDelay(), 34);
    }

    function testSetVotingPeriod() public {
        vm.expectRevert("UNAUTHORIZED");
        governor.setVotingPeriod(12);

        vm.prank(governorAddress);
        governor.setVotingPeriod(34);
        assertEq(governor.votingPeriod(), 34);
    }

    function testSetProposalThreshold() public {
        vm.expectRevert("UNAUTHORIZED");
        governor.setProposalThreshold(12);

        vm.prank(governorAddress);
        governor.setProposalThreshold(34);
        assertEq(governor.proposalThreshold(), 34);
    }

    function testSetQuorum() public {
        vm.expectRevert("UNAUTHORIZED");
        governor.setQuorum(12);

        vm.prank(governorAddress);
        governor.setQuorum(34);
        assertEq(governor.quorum(999), 34);
    }

    function testRelay() public {
        // deal ETH to the governor
        vm.deal(address(governor), 10 ether);

        // proposal calls
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(
            Governor.relay.selector,
            address(this),
            10 ether,
            bytes("")
        );

        // propose a new vote
        token.mockSetVotes(address(this), _QUORUM);
        uint256 proposalId = governor.propose(
            targets,
            values,
            payloads,
            "relay ETH back"
        );
        vm.roll(block.number + _VOTING_DELAY + 1);
        vm.warp(block.timestamp + 10);
        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 10);
        governor.queue(targets, values, payloads, keccak256("relay ETH back"));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 1);
        assertEq(address(governor).balance, 10 ether);
        uint256 balanceBefore = address(this).balance;
        governor.execute(
            targets,
            values,
            payloads,
            keccak256("relay ETH back")
        );
        uint256 balanceAfter = address(this).balance;

        // the governor sent its 10 ETH away
        assertEq(balanceAfter - balanceBefore, 10 ether);
        assertEq(address(governor).balance, 0);
    }
}
