// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {VoltGovernor} from "@src/governance/VoltGovernor.sol";

/// @notice Utils to onboard a LendingTerm. Also acts as a LendingTerm factory.
/// This contract acts as Governor, but users cannot queue arbitrary proposals,
/// they can only queue LendingTerm onboarding proposals.
/// When a vote is successful, the LendingTerm onboarding is queued in the Timelock,
/// where CREDIT holders can veto the onboarding.
/// Only terms that have been deployed through this factory can be onboarded.
/// A term can be onboarded for the first time, or re-onboarded after it has been offboarded.
contract LendingTermOnboarding is VoltGovernor {

    /// @notice minimum delay between proposals of onboarding of a given term
    uint256 MIN_DELAY_BETWEEN_PROPOSALS = 7 days;
    /// @notice time of last proposal of a given term
    mapping(address=>uint256) public lastProposal;

    /// @notice immutable reference to the lending term implementation to clone
    address public immutable lendingTermImplementation;
    /// @notice immutable reference to the guild token
    address public immutable guildToken;
    /// @notice immutable reference to the gauge type to use for the terms onboarded
    uint256 public immutable gaugeType;

    /// @notice timestamp of creation of a term
    /// (used to check that a term has been created by this factory)
    mapping(address=>uint256) public created;

    constructor(
        address _lendingTermImplementation,
        address _guildToken,
        uint256 _gaugeType,
        address _core,
        address _timelock,
        uint256 initialVotingDelay,
        uint256 initialVotingPeriod,
        uint256 initialProposalThreshold,
        uint256 initialQuorum
    )
        VoltGovernor(
            _core,
            _timelock,
            _guildToken,
            initialVotingDelay,
            initialVotingPeriod,
            initialProposalThreshold,
            initialQuorum
        )
    {
        lendingTermImplementation = _lendingTermImplementation;
        guildToken = _guildToken;
        gaugeType = _gaugeType;
    }

    /// @notice Create a new LendingTerm and initialize it.
    function createTerm(LendingTerm.LendingTermParams calldata params) external returns (address) {
        address term = Clones.clone(lendingTermImplementation);
        LendingTerm(term).initialize(
            address(LendingTerm(lendingTermImplementation).core()),
            LendingTerm(lendingTermImplementation).getReferences(),
            params
        );
        created[term] = block.timestamp;
        return term;
    }

    /// @dev override to prevent arbitrary calls to be proposed
    function propose(
        address[] memory /* targets*/,
        uint256[] memory /* values*/,
        bytes[] memory /* calldatas*/,
        string memory /* description*/
    ) public pure override(IGovernor, Governor) returns (uint256) {
        revert("LendingTermOnboarding: cannot propose arbitrary actions");
    }

    /// @notice Propose the onboarding of a term
    function proposeOnboard(address term) external returns (uint256 proposalId) {
        // Check that the term has been created by this factory
        require(created[term] != 0, "LendingTermOnboarding: invalid term");

        // Check that the term was not subject to an onboard vote recently
        require(lastProposal[term] + MIN_DELAY_BETWEEN_PROPOSALS < block.timestamp, "LendingTermOnboarding: recently proposed");
        lastProposal[term] = block.timestamp;
        
        // Check that the term is not already active
        // note that terms that have been offboarded in the past can be re-onboarded
        // and won't fail this check. This is intentional, because some terms might be offboarded
        // due to specific market conditions, and it might be desirable to re-onboard them
        // at a later date.
        bool isGauge = GuildToken(guildToken).isGauge(term);
        require(!isGauge, "LendingTermOnboarding: active term");

        // Generate calldata for the proposal
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = getOnboardProposeArgs(term);

        // propose
        return Governor.propose(targets, values, calldatas, description);
    }

    /// @notice Generate the calldata for the onboarding of a term
    function getOnboardProposeArgs(address term) public view returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) {
        targets = new address[](3);
        values = new uint256[](3);
        calldatas = new bytes[](3);
        description = string.concat("Enable term ", Strings.toHexString(uint160(term), 20));

        // 1st call: guild.addGauge(term)
        targets[0] = guildToken;
        calldatas[0] = abi.encodeWithSelector(
            GuildToken.addGauge.selector,
            gaugeType,
            term
        );

        // 2nd call: core.grantRole(term, RATE_LIMITED_CREDIT_MINTER)
        address _core = address(core());
        targets[1] = _core;
        calldatas[1] = abi.encodeWithSelector(
            AccessControl.grantRole.selector,
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            term
        );

        // 3rd call: core.grantRole(term, GAUGE_PNL_NOTIFIER)
        targets[2] = _core;
        calldatas[2] = abi.encodeWithSelector(
            AccessControl.grantRole.selector,
            CoreRoles.GAUGE_PNL_NOTIFIER,
            term
        );
    }
}
