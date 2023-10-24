// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    uint256 public constant MIN_DELAY_BETWEEN_PROPOSALS = 7 days;
    /// @notice time of last proposal of a given term
    mapping(address => uint256) public lastProposal;

    /// @notice immutable reference to the lending term implementation to clone
    address public immutable lendingTermImplementation;
    /// @notice immutable reference to the guild token
    address public immutable guildToken;
    /// @notice immutable reference to the gauge type to use for the terms onboarded
    uint256 public immutable gaugeType;

    /// @notice timestamp of creation of a term
    /// (used to check that a term has been created by this factory)
    mapping(address => uint256) public created;

    /// @notice reference to profitManager to set in created lending terms
    address public immutable profitManager;
    /// @notice reference to auctionHouse to set in created lending terms
    address public immutable auctionHouse;
    /// @notice reference to creditMinter to set in created lending terms
    address public immutable creditMinter;
    /// @notice reference to creditToken to set in created lending terms
    address public immutable creditToken;

    constructor(
        address _lendingTermImplementation,
        LendingTerm.LendingTermReferences memory _lendingTermReferences,
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
            _lendingTermReferences.guildToken,
            initialVotingDelay,
            initialVotingPeriod,
            initialProposalThreshold,
            initialQuorum
        )
    {
        lendingTermImplementation = _lendingTermImplementation;
        guildToken = _lendingTermReferences.guildToken;
        gaugeType = _gaugeType;
        profitManager = _lendingTermReferences.profitManager;
        auctionHouse = _lendingTermReferences.auctionHouse;
        creditMinter = _lendingTermReferences.creditMinter;
        creditToken = _lendingTermReferences.creditToken;
    }

    /// @notice Create a new LendingTerm and initialize it.
    function createTerm(
        LendingTerm.LendingTermParams calldata params
    ) external returns (address) {
        // must be an ERC20 (maybe, at least it prevents dumb input mistakes)
        (bool success, bytes memory returned) = params.collateralToken.call(
            abi.encodeWithSelector(IERC20.totalSupply.selector)
        );
        require(
            success && returned.length == 32,
            "LendingTermOnboarding: invalid collateralToken"
        );

        require(
            params.maxDebtPerCollateralToken != 0, // must be able to mint non-zero debt
            "LendingTermOnboarding: invalid maxDebtPerCollateralToken"
        );

        require(
            params.interestRate < 1e18, // interest rate [0, 100[% APR
            "LendingTermOnboarding: invalid interestRate"
        );

        require(
            // 31557601 comes from the constant LendingTerm.YEAR() + 1
            params.maxDelayBetweenPartialRepay < 31557601, // periodic payment every [0, 1 year]
            "LendingTermOnboarding: invalid maxDelayBetweenPartialRepay"
        );

        require(
            params.minPartialRepayPercent < 1e18, // periodic payment sizes [0, 100[%
            "LendingTermOnboarding: invalid minPartialRepayPercent"
        );

        require(
            params.openingFee <= 0.1e18, // open fee expected [0, 10]%
            "LendingTermOnboarding: invalid openingFee"
        );

        require(
            params.hardCap != 0, // non-zero hardcap
            "LendingTermOnboarding: invalid hardCap"
        );

        address term = Clones.clone(lendingTermImplementation);
        LendingTerm(term).initialize(
            address(core()),
            LendingTerm.LendingTermReferences({
                profitManager: profitManager,
                guildToken: guildToken,
                auctionHouse: auctionHouse,
                creditMinter: creditMinter,
                creditToken: creditToken
            }),
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
    function proposeOnboard(
        address term
    ) external whenNotPaused returns (uint256 proposalId) {
        // Check that the term has been created by this factory
        require(created[term] != 0, "LendingTermOnboarding: invalid term");

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
        targets = new address[](3);
        values = new uint256[](3);
        calldatas = new bytes[](3);
        description = string.concat(
            "Enable term ",
            Strings.toHexString(uint160(term), 20)
        );

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
