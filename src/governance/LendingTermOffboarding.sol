// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";

/// @notice Utils to offboard a LendingTerm.
/// This contract works somewhat similarly to a Veto governor: any GUILD holder can poll for the removal
/// of a lending term, and if enough GUILD holders vote for a removal poll, the term can be offboarded
/// without delay.
/// When a term is offboarded, no new loans can be issued, and GUILD holders cannot vote for the term anymore.
/// After a term is offboarded, all the loans have to be called, then the term can be cleaned up (roles).
contract LendingTermOffboarding is CoreRef {
    /// @notice emitted when a user supports the removal of a lending term
    event OffboardSupport(
        uint256 indexed timestamp,
        address indexed term,
        uint256 indexed snapshotBlock,
        address user,
        uint256 userWeight
    );
    /// @notice emitted when a lending term is offboarded
    event Offboard(uint256 indexed timestamp, address indexed term);
    /// @notice emitted when a lending term is cleaned up
    event Cleanup(uint256 indexed timestamp, address indexed term);

    /// @notice Emitted when quorum is updated.
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    /// @notice maximum age of polls for them to be considered valid.
    /// This offboarding mechanism is meant to be used in a reactive fashion, and
    /// polls should not stay open for a long time.
    uint256 public constant POLL_DURATION_BLOCKS = 50400; // ~7 days @ 12s/block

    /// @notice quorum for offboarding a lending term
    uint256 public quorum;

    /// @notice reference to the GUILD token
    address public immutable guildToken;

    /// @notice reference to the LendingTermFactory
    address public immutable factory;

    /// @notice list of removal polls created.
    /// keys = [snapshotBlock][termAddress] -> quorum supporting the removal.
    mapping(uint256 => mapping(address => uint256)) public polls;

    /// @notice list of user votes in removal polls
    /// keys = [userAddress][snapshotBlock][termAddress] -> user vote weight.
    mapping(address => mapping(uint256 => mapping(address => uint256)))
        public userPollVotes;

    /// @notice block number of last removal polls created for each term.
    /// key = [termAddress] -> block number.
    mapping(address => uint256) public lastPollBlock;

    /// @notice mapping of terms that can be offboarded.
    mapping(address => OffboardStatus) public canOffboard;
    enum OffboardStatus {
        UNSET,
        CAN_OFFBOARD,
        CAN_CLEANUP
    }

    /// @notice number of offboardings in progress.
    uint256 public nOffboardingsInProgress;

    constructor(
        address _core,
        address _guildToken,
        address _factory,
        uint256 _quorum
    ) CoreRef(_core) {
        guildToken = _guildToken;
        factory = _factory;
        quorum = _quorum;
    }

    /// @notice set the quorum for offboard votes
    function setQuorum(
        uint256 _quorum
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        emit QuorumUpdated(quorum, _quorum);
        quorum = _quorum;
    }

    /// @notice Propose to offboard a given LendingTerm.
    /// @dev the poll starts with 1 wei of voting power, to initialize the storage slot
    /// that counts the number of user supports (a value of 0 is used as the existence
    /// check to know if a poll has been created).
    function proposeOffboard(address term) external whenNotPaused {
        require(
            polls[block.number][term] == 0,
            "LendingTermOffboarding: poll exists"
        );
        require(
            block.number > lastPollBlock[term] + POLL_DURATION_BLOCKS,
            "LendingTermOffboarding: poll active"
        );
        // Check that the term is an active gauge
        require(
            GuildToken(guildToken).isGauge(term),
            "LendingTermOffboarding: not an active term"
        );
        // Check that another offboarding is not in progress
        require(
            canOffboard[term] == OffboardStatus.UNSET,
            "LendingTermOffboarding: offboard in progress"
        );

        polls[block.number][term] = 1; // voting power
        lastPollBlock[term] = block.number;
        emit OffboardSupport(
            block.timestamp,
            term,
            block.number,
            address(0),
            1
        );
    }

    /// @notice Support a poll to offboard a given LendingTerm.
    function supportOffboard(
        uint256 snapshotBlock,
        address term
    ) external whenNotPaused {
        require(
            block.number <= snapshotBlock + POLL_DURATION_BLOCKS,
            "LendingTermOffboarding: poll expired"
        );
        uint256 _weight = polls[snapshotBlock][term];
        require(_weight != 0, "LendingTermOffboarding: poll not found");
        uint256 userWeight = GuildToken(guildToken).getPastVotes(
            msg.sender,
            snapshotBlock
        );
        require(userWeight != 0, "LendingTermOffboarding: zero weight");
        require(
            userPollVotes[msg.sender][snapshotBlock][term] == 0,
            "LendingTermOffboarding: already voted"
        );
        // Check that offboarding vote is still ongoing
        require(
            canOffboard[term] == OffboardStatus.UNSET,
            "LendingTermOffboarding: offboard vote ended"
        );
        require(
            lastPollBlock[term] == snapshotBlock,
            "LendingTermOffboarding: new poll exists"
        );

        userPollVotes[msg.sender][snapshotBlock][term] = userWeight;
        polls[snapshotBlock][term] = _weight + userWeight;
        if (_weight + userWeight >= quorum) {
            canOffboard[term] = OffboardStatus.CAN_OFFBOARD;
        }
        emit OffboardSupport(
            block.timestamp,
            term,
            snapshotBlock,
            msg.sender,
            userWeight
        );
    }

    /// @notice Offboard a LendingTerm.
    /// This will prevent new loans from being open, and will prevent GUILD holders to vote for the term.
    /// @param term LendingTerm to offboard from the system.
    function offboard(address term) external whenNotPaused {
        require(
            canOffboard[term] == OffboardStatus.CAN_OFFBOARD,
            "LendingTermOffboarding: cannot offboard"
        );
        canOffboard[term] = OffboardStatus.CAN_CLEANUP;
        lastPollBlock[term] = 1; // not 0 to reduce gas cost of next offboard

        // update protocol config
        // this will revert if the term has already been offboarded
        // through another mean.
        GuildToken(guildToken).removeGauge(term);

        // if there are no other offboardings in progress, this is the
        // first offboarding to start, so we pause psm redemptions
        (, , , address psm) = LendingTermFactory(factory).marketReferences(
            LendingTermFactory(factory).gaugeTypes(term)
        );
        if (
            nOffboardingsInProgress++ == 0 &&
            !SimplePSM(psm).redemptionsPaused()
        ) {
            SimplePSM(psm).setRedemptionsPaused(true);
        }

        emit Offboard(block.timestamp, term);
    }

    /// @notice Cleanup roles of a LendingTerm.
    /// This is only callable after a term has been offboarded and all its loans have been closed.
    /// @param term LendingTerm to cleanup.
    function cleanup(address term) external whenNotPaused {
        require(
            LendingTerm(term).issuance() == 0,
            "LendingTermOffboarding: not all loans closed"
        );
        require(
            GuildToken(guildToken).isDeprecatedGauge(term) &&
                core().hasRole(CoreRoles.CREDIT_BURNER, term) &&
                core().hasRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, term) &&
                core().hasRole(CoreRoles.GAUGE_PNL_NOTIFIER, term),
            "LendingTermOffboarding: re-onboarded"
        );
        require(
            canOffboard[term] == OffboardStatus.CAN_CLEANUP,
            "LendingTermOffboarding: cannot cleanup"
        );
        canOffboard[term] = OffboardStatus.UNSET;

        // update protocol config
        core().revokeRole(CoreRoles.CREDIT_BURNER, term);
        core().revokeRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, term);
        core().revokeRole(CoreRoles.GAUGE_PNL_NOTIFIER, term);

        // if there are no other offboardings in progress, this is the
        // last offboarding to end, so we unpause psm redemptions
        (, , , address psm) = LendingTermFactory(factory).marketReferences(
            LendingTermFactory(factory).gaugeTypes(term)
        );
        if (
            --nOffboardingsInProgress == 0 && SimplePSM(psm).redemptionsPaused()
        ) {
            SimplePSM(psm).setRedemptionsPaused(false);
        }

        emit Cleanup(block.timestamp, term);
    }

    /// @notice Can reset an offboarding process if the term has been re-onboarded
    /// The offboard flow looks like the following :
    /// - 1) proposeOffboard()
    /// - 2) supportOffboard()
    /// - 3) offboard()
    /// - 3a) if not re-onboarded before cleanup, cleanup()
    /// - 3b) if re-onboarded before cleanup, resetOffboarding()
    /// @param term LendingTerm to reset offboarding for.
    function resetOffboarding(address term) external whenNotPaused {
        require(
            canOffboard[term] != OffboardStatus.UNSET,
            "LendingTermOffboarding: cannot reset"
        );
        require(
            GuildToken(guildToken).isGauge(term) &&
                core().hasRole(CoreRoles.CREDIT_BURNER, term) &&
                core().hasRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, term) &&
                core().hasRole(CoreRoles.GAUGE_PNL_NOTIFIER, term),
            "LendingTermOffboarding: not re-onboarded"
        );

        // if there are no other offboardings in progress, this is the
        // last offboarding to end, so we unpause psm redemptions
        (, , , address psm) = LendingTermFactory(factory).marketReferences(
            LendingTermFactory(factory).gaugeTypes(term)
        );
        if (
            --nOffboardingsInProgress == 0 && SimplePSM(psm).redemptionsPaused()
        ) {
            SimplePSM(psm).setRedemptionsPaused(false);
        }

        canOffboard[term] = OffboardStatus.UNSET;
        lastPollBlock[term] = 1; // not 0 to reduce gas cost of next offboard
    }
}
