// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";

import {GuildToken} from "@src/tokens/GuildToken.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";

/// @notice Utils to update parameters of lending terms.
/// This contract acts as Governor, but users cannot queue arbitrary proposals,
/// they can only queue LendingTerm parameter update proposals.
/// When a vote is successful, the param update is queued in the Timelock,
/// where CREDIT holders can veto the change.
contract LendingTermParamManager is GuildGovernor {
    constructor(
        address _core,
        address _timelock,
        address _guildToken,
        uint256 initialVotingDelay,
        uint256 initialVotingPeriod,
        uint256 initialProposalThreshold,
        uint256 initialQuorum
    )
        GuildGovernor(
            _core,
            _timelock,
            _guildToken,
            initialVotingDelay,
            initialVotingPeriod,
            initialProposalThreshold,
            initialQuorum
        )
    {}

    /// @dev override to prevent arbitrary calls to be proposed
    function propose(
        address[] memory /* targets*/,
        uint256[] memory /* values*/,
        bytes[] memory /* calldatas*/,
        string memory /* description*/
    ) public pure override(IGovernor, Governor) returns (uint256) {
        revert("LendingTermParamManager: cannot propose arbitrary actions");
    }

    /// @dev override to prevent cancellation from the proposer
    function cancel(
        address[] memory /* targets*/,
        uint256[] memory /* values*/,
        bytes[] memory /* calldatas*/,
        bytes32 /* descriptionHash*/
    ) public pure override(IGovernor, Governor) returns (uint256) {
        revert("LendingTermParamManager: cannot cancel proposals");
    }

    /// @notice propose an update of borrow ratio
    function proposeSetMaxDebtPerCollateralToken(
        address term,
        uint256 borrowRatio
    ) external whenNotPaused returns (uint256 proposalId) {
        // check that the term is active
        require(
            GuildToken(address(token)).isGauge(term),
            "LendingTermParamManager: inactive term"
        );

        // build proposal
        address[] memory targets = new address[](1);
        targets[0] = term;
        uint256[] memory values = new uint256[](1); // [0]
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setMaxDebtPerCollateralToken(uint256)",
            borrowRatio
        );
        string memory description = string.concat(
            "Update borrow ratio\n\n[",
            Strings.toString(block.number),
            "]",
            " set maxDebtPerCollateralToken of term ",
            Strings.toHexString(term),
            " to ",
            Strings.toString(borrowRatio)
        );

        // propose
        return Governor.propose(targets, values, calldatas, description);
    }

    /// @notice propose an update of interestRate
    function proposeSetInterestRate(
        address term,
        uint256 interestRate
    ) external whenNotPaused returns (uint256 proposalId) {
        // check that the term is active
        require(
            GuildToken(address(token)).isGauge(term),
            "LendingTermParamManager: inactive term"
        );

        // build proposal
        address[] memory targets = new address[](1);
        targets[0] = term;
        uint256[] memory values = new uint256[](1); // [0]
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setInterestRate(uint256)",
            interestRate
        );
        string memory description = string.concat(
            "Update interest rate\n\n[",
            Strings.toString(block.number),
            "]",
            " set interestRate of term ",
            Strings.toHexString(term),
            " to ",
            Strings.toString(interestRate)
        );

        // propose
        return Governor.propose(targets, values, calldatas, description);
    }

    /// @notice propose an update of hardCap
    function proposeSetHardCap(
        address term,
        uint256 hardCap
    ) external whenNotPaused returns (uint256 proposalId) {
        // check that the term is active
        require(
            GuildToken(address(token)).isGauge(term),
            "LendingTermParamManager: inactive term"
        );

        // build proposal
        address[] memory targets = new address[](1);
        targets[0] = term;
        uint256[] memory values = new uint256[](1); // [0]
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setHardCap(uint256)",
            hardCap
        );
        string memory description = string.concat(
            "Update hard cap\n\n[",
            Strings.toString(block.number),
            "]",
            " set hardCap of term ",
            Strings.toHexString(term),
            " to ",
            Strings.toString(hardCap)
        );

        // propose
        return Governor.propose(targets, values, calldatas, description);
    }
}
