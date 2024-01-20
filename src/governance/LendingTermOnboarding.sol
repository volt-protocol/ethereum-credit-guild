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
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";

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

    /// @notice mapping of allowed LendingTerm implementations
    mapping(address => bool) public implementations;
    /// @notice mapping of allowed AuctionHouses
    mapping(address => bool) public auctionHouses;
    /// @notice immutable reference to the guild token
    address public immutable guildToken;

    /// @notice gaugeType of created terms
    /// note that gaugeType 0 is not valid, so this mapping can be used
    /// to check that a term has been created by this factory.
    mapping(address => uint256) public gaugeTypes;

    /// @notice mapping of references per market (key = gaugeType = market id)
    mapping(uint256 => MarketReferences) public marketReferences;
    struct MarketReferences {
        address profitManager;
        address creditMinter;
        address creditToken;
    }

    /// @notice emitted when a lending term implementation's "allowed" status changes
    event ImplementationAllowChanged(
        uint256 indexed when,
        address indexed implementation,
        bool allowed
    );
    /// @notice emitted when an auctionHouse's "allowed" status changes
    event AuctionHouseAllowChanged(
        uint256 indexed when,
        address indexed auctionHouses,
        bool allowed
    );
    /// @notice emitted when a term is created
    event TermCreated(
        uint256 indexed when,
        address indexed implementation,
        address indexed term,
        LendingTerm.LendingTermParams params
    );

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
    {
        guildToken = _guildToken;
    }

    /// @notice set market references for a given market id
    function setMarketReferences(
        uint256 gaugeType,
        MarketReferences calldata references
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        marketReferences[gaugeType] = references;
    }

    /// @notice Allow or disallow a given implemenation
    function allowImplementation(
        address implementation,
        bool allowed
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        implementations[implementation] = allowed;
        emit ImplementationAllowChanged(
            block.timestamp,
            implementation,
            allowed
        );
    }

    /// @notice Allow or disallow a given auctionHouse
    function allowAuctionHouse(
        address auctionHouse,
        bool allowed
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        auctionHouses[auctionHouse] = allowed;
        emit AuctionHouseAllowChanged(
            block.timestamp,
            auctionHouse,
            allowed
        );
    }

    /// @notice Create a new LendingTerm and initialize it.
    function createTerm(
        uint256 gaugeType,
        address implementation,
        address auctionHouse,
        LendingTerm.LendingTermParams calldata params
    ) external returns (address) {
        require(
            implementations[implementation],
            "LendingTermOnboarding: invalid implementation"
        );
        require(
            auctionHouses[auctionHouse],
            "LendingTermOnboarding: invalid auctionHouse"
        );
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

        // if one of the periodic payment parameter is used, both must be used
        if (params.minPartialRepayPercent != 0 || params.maxDelayBetweenPartialRepay != 0) {
            require(
                params.minPartialRepayPercent != 0 && params.maxDelayBetweenPartialRepay != 0,
                "LendingTermOnboarding: invalid periodic payment params"
            );
        }

        // check that references for this market has been set
        MarketReferences storage references = marketReferences[gaugeType];
        require(references.profitManager != address(0), "LendingTermOnboarding: unknown market");

        address term = Clones.clone(implementation);
        LendingTerm(term).initialize(
            address(core()),
            LendingTerm.LendingTermReferences({
                profitManager: references.profitManager,
                guildToken: guildToken,
                auctionHouse: auctionHouse,
                creditMinter: references.creditMinter,
                creditToken: references.creditToken
            }),
            params
        );
        gaugeTypes[term] = gaugeType;
        emit TermCreated(block.timestamp, implementation, term, params);
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
        require(gaugeTypes[term] != 0, "LendingTermOnboarding: invalid term");

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
            "[",
            Strings.toString(block.number),
            "]",
            " Enable term ",
            Strings.toHexString(term)
        );

        // 1st call: guild.addGauge(term)
        targets[0] = guildToken;
        calldatas[0] = abi.encodeWithSelector(
            GuildToken.addGauge.selector,
            gaugeTypes[term],
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
