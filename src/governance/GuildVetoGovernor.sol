// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes, IERC165} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

/// @title Governor for on-chain governance of Ethereum Credit Guild, based on the OZ implementation.
/// This governor is specifically designed for adding veto capabilities :
/// Token holders cannot propose() arbitrary actions, they have to create the proposals
/// through the createVeto() function, and this governor will only be able to execute the
/// action of cancelling an action in the linked TimelockController if the veto vote passes.
/// Token holders can only vote against an action that is queued in the linked TimelockController.
/// When enough against votes (above veto quorum) are cast, the veto vote is considered successful,
/// and this governor can early-execute the proposal of cancelling the action in the linked
/// TimelockController, without having to wait the end of a voting period.
/// After the action has been queued in the linked TimelockController for enough time to be
/// executed, the veto vote is considered failed and the action cannot be cancelled anymore.
/// @author eswak
contract GuildVetoGovernor is CoreRef, Governor, GovernorVotes {
    /// @notice Private storage variable for quorum (the minimum number of votes needed for a vote to pass).
    uint256 private _quorum;

    /// @notice Emitted when quorum is updated.
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    constructor(
        address _core,
        address initialTimelock,
        address _token,
        uint256 initialQuorum
    )
        CoreRef(_core)
        Governor("ECG Veto Governor")
        GovernorVotes(IVotes(_token))
    {
        _setQuorum(initialQuorum);
        _updateTimelock(initialTimelock);
    }

    /// ------------------------------------------------------------------------
    /// Quorum Management
    /// ------------------------------------------------------------------------

    /**
     * @dev Public accessor to check the minimum number of votes needed for a vote to pass.
     */
    function quorum(
        uint256 /* blockNumber*/
    ) public view override returns (uint256) {
        return _quorum;
    }

    /// @notice Adjust quorum, restricted to Core GOVERNOR role.
    function setQuorum(
        uint256 newQuorum
    ) public onlyCoreRole(CoreRoles.GOVERNOR) {
        _setQuorum(newQuorum);
    }

    /**
     * @dev Internal setter for the proposal quorum.
     *
     * Emits a {QuorumUpdated} event.
     */
    function _setQuorum(uint256 newQuorum) internal virtual {
        emit QuorumUpdated(_quorum, newQuorum);
        _quorum = newQuorum;
    }

    /// ------------------------------------------------------------------------
    /// Timelock Management
    /// ------------------------------------------------------------------------

    /**
     * @dev Emitted when the timelock controller used for proposal execution is modified.
     */
    event TimelockChange(address oldTimelock, address newTimelock);

    /// @notice the timelock linked to this veto governor
    address public timelock;

    /// @notice mapping of proposalId (in this Governor) to timelockId (action ID in
    /// the timelock linked to this governor).
    mapping(uint256 => bytes32) private _timelockIds;

    /// @notice Set the timelock this veto governor can cancel from.
    function updateTimelock(
        address newTimelock
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _updateTimelock(newTimelock);
    }

    function _updateTimelock(address newTimelock) private {
        emit TimelockChange(timelock, newTimelock);
        timelock = newTimelock;
    }

    /// ------------------------------------------------------------------------
    /// Vote counting
    /// ------------------------------------------------------------------------

    /**
     * @dev Supported vote types. Matches Governor Bravo ordering.
     */
    enum VoteType {
        Against,
        For,
        Abstain
    }

    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
    }

    mapping(uint256 => ProposalVote) private _proposalVotes;

    /**
     * @dev See {IGovernor-COUNTING_MODE}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE()
        public
        pure
        virtual
        override
        returns (string memory)
    {
        return "support=bravo&quorum=against";
    }

    /**
     * @dev See {IGovernor-hasVoted}.
     */
    function hasVoted(
        uint256 proposalId,
        address account
    ) public view virtual override returns (bool) {
        return _proposalVotes[proposalId].hasVoted[account];
    }

    /**
     * @dev Accessor to the internal vote counts.
     */
    function proposalVotes(
        uint256 proposalId
    )
        public
        view
        virtual
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
    {
        // againstVotes are supporting the execution of Veto
        againstVotes = _proposalVotes[proposalId].againstVotes;
        // no forVotes can be cast in the Veto module, keep 0 value
        forVotes = 0;
        // no abstainVotes can be cast in the Veto module, keep 0 value
        abstainVotes = 0;
    }

    /**
     * @dev See {Governor-_quorumReached}.
     */
    function _quorumReached(
        uint256 proposalId
    ) internal view virtual override returns (bool) {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];

        return
            quorum(proposalSnapshot(proposalId)) <= proposalvote.againstVotes;
    }

    /**
     * @dev Veto votes are always considered "successful" in this part of the logic, as there is no opposition
     * between 'for' and 'against' votes, since people cannot vote 'for'. For a veto to be considered successful,
     * it only needs to reach quorum.
     */
    function _voteSucceeded(
        uint256 /* proposalId*/
    ) internal pure virtual override returns (bool) {
        return true;
    }

    /**
     * @dev See {Governor-_countVote}. In this module, the support follows the `VoteType` enum (from Governor Bravo).
     */
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory // params
    ) internal virtual override {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];

        require(
            !proposalvote.hasVoted[account],
            "GuildVetoGovernor: vote already cast"
        );
        proposalvote.hasVoted[account] = true;

        if (support == uint8(VoteType.Against)) {
            proposalvote.againstVotes += weight;
        } else {
            revert("GuildVetoGovernor: can only vote against in veto proposals");
        }
    }

    /// ------------------------------------------------------------------------
    /// Public functions override
    /// ------------------------------------------------------------------------

    /// @dev no voting delay between veto proposal and veto voting period.
    function votingDelay() public pure override returns (uint256) {
        return 0;
    }

    /// @dev voting period is unused, it is a duration in blocks for the vote
    /// but the timestamp of the action in the timelock is used to know if the
    /// vote period is over (after action is ready in the timelock, the veto
    /// vote failed).
    function votingPeriod() public pure override returns (uint256) {
        return 2425847; // ~1 year with 1 block every 13s
    }

    /// @notice State of a given proposal
    /// The state can be one of:
    /// - ProposalState.Pending   (0) Lasts only during the block where the veto proposal has been created.
    /// - ProposalState.Active    (1) If action is pending in the timelock and veto quorum has not been reached yet.
    /// - ProposalState.Canceled  (2) If a veto was created but the timelock action has been cancelled through another
    ///   mean before the veto vote succeeded. The internal _cancel() function is not reachable by another mean (no
    ///   public cancel() function), so this is the only case where a proposal will have Canceled status.
    /// - ProposalState.Defeated  (3) If proposal already executed or is ready to execute in the timelock.
    /// - ProposalState.Succeeded (4) If action is pending in the timelock and veto quorum has been reached. Veto can be executed instantly.
    /// - ProposalState.Executed  (7) If a veto successfully executed.
    /// note that veto proposals have a quorum that works with 'against' votes, and that only 'against' votes can be
    /// cast in this veto governor.
    function state(
        uint256 proposalId
    ) public view override returns (ProposalState) {
        ProposalState status = super.state(proposalId);
        bytes32 queueid = _timelockIds[proposalId];

        // @dev all proposals that are in this Governor's state should have been created
        // by the createVeto() method, and therefore should have _timelockIds set, so this
        // condition check is an invalid state that should never be reached.
        assert(queueid != bytes32(0));

        // Proposal already executed and stored in state
        if (status == ProposalState.Executed) {
            return ProposalState.Executed;
        }
        // Proposal cannot be Canceled because there is no public cancel() function.
        // Vote has just been created, still in waiting period
        if (status == ProposalState.Pending) {
            return ProposalState.Pending;
        }

        // at this stage, status from super can be one of: Active, Succeeded, Defeated
        // Read timestamp in the timelock to determine the state of the proposal
        uint256 timelockOperationTimestamp = TimelockController(
            payable(timelock)
        ).getTimestamp(queueid);

        // proposal already cleared from the timelock by something else
        if (timelockOperationTimestamp == 0) {
            return ProposalState.Canceled;
        }
        // proposal already executed in the timelock
        if (timelockOperationTimestamp == 1) {
            return ProposalState.Defeated;
        }

        // proposal still in waiting period in the timelock
        if (timelockOperationTimestamp > block.timestamp) {
            // ready to veto
            // no need for "&& _voteSucceeded(proposalId)" in condition because
            // veto votes are always succeeded (there is no tallying for 'for'
            // votes against 'against' votes), the only condition is the quorum.
            if (_quorumReached(proposalId)) {
                return ProposalState.Succeeded;
            }
            // need more votes to veto
            else {
                return ProposalState.Active;
            }
        }
        // proposal is ready to execute in the timelock, the veto
        // vote did not reach quorum in time.
        else {
            return ProposalState.Defeated;
        }
    }

    /// @dev override to prevent arbitrary calls to be proposed
    function propose(
        address[] memory /* targets*/,
        uint256[] memory /* values*/,
        bytes[] memory /* calldatas*/,
        string memory /* description*/
    ) public pure override returns (uint256) {
        revert("GuildVetoGovernor: cannot propose arbitrary actions");
    }

    /// @notice Propose a governance action to veto (cancel) a target action ID in the
    /// governor's linked timelock.
    function createVeto(bytes32 timelockId) external returns (uint256) {
        // Check that the operation is pending in the timelock
        uint256 timelockExecutionTime = TimelockController(payable(timelock))
            .getTimestamp(timelockId);
        require(
            timelockExecutionTime > 1,
            "GuildVetoGovernor: action must be pending"
        );

        // Build proposal data
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _getVetoCalls(timelockId);

        uint256 proposalId = super.propose(
            targets,
            values,
            calldatas,
            description
        );

        // Save mapping between proposalId and timelockId
        _timelockIds[proposalId] = timelockId;

        return proposalId;
    }

    /// @notice Execute a governance action to veto (cancel) a target action ID in the
    /// governor's linked timelock.
    /// @dev the standard execute() function can also be used for this, and the function
    /// is only added for convenience.
    function executeVeto(bytes32 timelockId) external returns (uint256) {
        // Build proposal data
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _getVetoCalls(timelockId);
        // Execute
        return
            super.execute(
                targets,
                values,
                calldatas,
                keccak256(bytes(description))
            );
    }

    function _getVetoCalls(
        bytes32 timelockId
    )
        internal
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        )
    {
        targets = new address[](1);
        targets[0] = timelock;
        values = new uint256[](1); // 0 eth
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            TimelockController.cancel.selector,
            timelockId
        );
        description = string.concat(
            "Veto proposal for ",
            string(abi.encodePacked(timelockId))
        );
    }
}
