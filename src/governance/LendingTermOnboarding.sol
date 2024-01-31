// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";

import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";

/// @notice Utils to onboard a LendingTerm. Also acts as a LendingTerm factory.
/// This contract acts as Governor, but users cannot queue arbitrary proposals,
/// they can only queue LendingTerm onboarding proposals.
/// When a vote is successful, the LendingTerm onboarding is queued in the Timelock,
/// where CREDIT holders can veto the onboarding.
/// Only terms that have been deployed through this factory can be onboarded.
/// A term can be onboarded for the first time, or re-onboarded after it has been offboarded.
contract LendingTermOnboarding is GuildGovernor {

    /// @notice minimum delay between proposals of onboarding of a given term
    uint256 public constant MIN_DELAY_BETWEEN_PROPOSALS = 7 days;
    /// @notice time of last proposal of a given term
    mapping(address => uint256) public lastProposal;

    /// @notice factory of lending terms where terms have to come from to be onboarded
    address public immutable factory;

    constructor(
        address _core,
        address _timelock,
        address _guildToken,
        uint256 initialVotingDelay,
        uint256 initialVotingPeriod,
        uint256 initialProposalThreshold,
        uint256 initialQuorum,
        address _factory
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
    {
        factory = _factory;
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

    /// @dev override to prevent cancellation from the proposer
    function cancel(
        address[] memory /* targets*/,
        uint256[] memory /* values*/,
        bytes[] memory /* calldatas*/,
        bytes32 /* descriptionHash*/
    ) public pure override(IGovernor, Governor) returns (uint256) {
        revert("LendingTermOnboarding: cannot cancel proposals");
    }

    /// @notice Propose the onboarding of a term
    function proposeOnboard(
        address term
    ) external whenNotPaused returns (uint256 proposalId) {
        // Check that the term has been created by this factory
        bool validImpl = LendingTermFactory(factory).implementations(
            LendingTermFactory(factory).termImplementations(term)
        );
        bool validAh = LendingTermFactory(factory).auctionHouses(
            LendingTerm(term).auctionHouse()
        );
        uint256 gaugeType = LendingTermFactory(factory).gaugeTypes(term);
        require(
            gaugeType != 0 && validImpl && validAh,
            "LendingTermOnboarding: invalid term"
        );

        // Check that the term was not subject to an onboard vote recently
        require(
            lastProposal[term] + MIN_DELAY_BETWEEN_PROPOSALS < block.timestamp,
            "LendingTermOnboarding: recently proposed"
        );
        lastProposal[term] = block.timestamp;

        // Check that the term is not already active
        // note that terms that have been offboarded in the past can be re-onboarded
        // and won't fail this check. This is intentional, because some terms might be offboarded
        // due to specific market conditions, and it might be desirable to re-onboard them
        // at a later date.
        bool isGauge = GuildToken(address(token)).isGauge(term);
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
    function getOnboardProposeArgs(
        address term
    )
        public
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        )
    {
        uint256 gaugeType = LendingTermFactory(factory).gaugeTypes(term);

        targets = new address[](4);
        values = new uint256[](4);
        calldatas = new bytes[](4);
        description = string.concat(
            "[",
            Strings.toString(block.number),
            "]",
            " Enable term ",
            Strings.toHexString(term)
        );

        // 1st call: guild.addGauge(term)
        targets[0] = address(token);
        calldatas[0] = abi.encodeWithSelector(
            GuildToken.addGauge.selector,
            gaugeType,
            term
        );

        // 2nd call: core.grantRole(term, CREDIT_BURNER)
        address _core = address(core());
        targets[1] = _core;
        calldatas[1] = abi.encodeWithSelector(
            AccessControl.grantRole.selector,
            CoreRoles.CREDIT_BURNER,
            term
        );

        // 3rd call: core.grantRole(term, RATE_LIMITED_CREDIT_MINTER)
        targets[2] = _core;
        calldatas[2] = abi.encodeWithSelector(
            AccessControl.grantRole.selector,
            CoreRoles.RATE_LIMITED_CREDIT_MINTER,
            term
        );

        // 4th call: core.grantRole(term, GAUGE_PNL_NOTIFIER)
        targets[3] = _core;
        calldatas[3] = abi.encodeWithSelector(
            AccessControl.grantRole.selector,
            CoreRoles.GAUGE_PNL_NOTIFIER,
            term
        );
    }
}
