// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes, IERC165} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

/// @title Governor for on-chain governance of Ethereum Credit Guild, based on the OZ implementation.
/// @author eswak
contract GuildGovernor is
    CoreRef,
    Governor,
    GovernorVotes,
    GovernorTimelockControl,
    GovernorSettings,
    GovernorCountingSimple
{
    /// @notice Private storage variable for quorum (the minimum number of votes needed for a vote to pass).
    uint256 private _quorum;

    /// @notice Emitted when quorum is updated.
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    constructor(
        address _core,
        address _timelock,
        address _token,
        uint256 initialVotingDelay,
        uint256 initialVotingPeriod,
        uint256 initialProposalThreshold,
        uint256 initialQuorum
    )
        CoreRef(_core)
        Governor("ECG Governor")
        GovernorVotes(IVotes(_token))
        GovernorTimelockControl(TimelockController(payable(_timelock)))
        GovernorSettings(
            initialVotingDelay,
            initialVotingPeriod,
            initialProposalThreshold
        )
    {
        _setQuorum(initialQuorum);
    }

    /// ------------------------------------------------------------------------
    /// Quorum managment.
    /// ------------------------------------------------------------------------

    /// @notice The minimum number of votes needed for a vote to pass.
    function quorum(
        uint256 /* blockNumber*/
    ) public view override returns (uint256) {
        return _quorum;
    }

    /**
     * @dev Internal setter for the proposal quorum.
     *
     * Emits a {QuorumUpdated} event.
     */
    function _setQuorum(uint256 newQuorum) internal {
        emit QuorumUpdated(_quorum, newQuorum);
        _quorum = newQuorum;
    }

    /// ------------------------------------------------------------------------
    /// Governor-only actions.
    /// ------------------------------------------------------------------------

    /// @notice Override of a GovernorSettings function, to restrict to Core GOVERNOR role.
    function setVotingDelay(
        uint256 newVotingDelay
    ) public override onlyCoreRole(CoreRoles.GOVERNOR) {
        _setVotingDelay(newVotingDelay);
    }

    /// @notice Override of a GovernorSettings function, to restrict to Core GOVERNOR role.
    function setVotingPeriod(
        uint256 newVotingPeriod
    ) public override onlyCoreRole(CoreRoles.GOVERNOR) {
        _setVotingPeriod(newVotingPeriod);
    }

    /// @notice Override of a GovernorSettings.sol function, to restrict to Core GOVERNOR role.
    function setProposalThreshold(
        uint256 newProposalThreshold
    ) public override onlyCoreRole(CoreRoles.GOVERNOR) {
        _setProposalThreshold(newProposalThreshold);
    }

    /// @notice Adjust quorum, restricted to Core GOVERNOR role.
    function setQuorum(
        uint256 newQuorum
    ) public onlyCoreRole(CoreRoles.GOVERNOR) {
        _setQuorum(newQuorum);
    }

    /// ------------------------------------------------------------------------
    /// Guardian-only actions.
    /// ------------------------------------------------------------------------

    /// @notice Allow guardian to cancel a proposal in progress.
    function guardianCancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public onlyCoreRole(CoreRoles.GUARDIAN) returns (uint256) {
        return _cancel(targets, values, calldatas, descriptionHash);
    }

    /// ------------------------------------------------------------------------
    /// Overrides required by Solidity.
    /// ------------------------------------------------------------------------

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function state(
        uint256 proposalId
    )
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
