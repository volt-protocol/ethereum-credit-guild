// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";

/// @notice Utils to offboard a LendingTerm.
/// This contracts works somewhat similarly to a Veto governor: any GUILD holder can poll for the removal
/// of a lending term, and if enough GUILD holders vote for a removal poll, the term can be offboarded.
contract LendingTermOffboarding is CoreRef {

    /// @notice emitted when a user supports the removal of a lending term
    event OffboardSupport(
        address indexed user,
        address indexed term,
        uint256 indexed snapshotBlock,
        uint256 userWeight
    );
    /// @notice emitted when a lending term is offboarded
    event Offboard(address indexed term);

    /// @notice Emitted when quorum is updated.
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    /// @notice maximum age of polls for them to be considered valid.
    /// This offboarding mechanism is meant to be used in a reactive fashion, and
    /// polls should not stay open for a long time.
    uint256 public constant POLL_DURATION_BLOCKS = 46523; // ~7 days @ 13s/block

    /// @notice quorum for offboarding a lending term
    uint256 public quorum;

    /// @notice reference to the GUILD token
    address public immutable guildToken;

    /// @notice list of removal polls created.
    /// keys = [snapshotBlock][termAddress] -> quorum supporting the removal.
    mapping(uint256=>mapping(address=>uint256)) public polls;

    /// @notice block number of last removal polls created for each term.
    /// key = [termAddress] -> block number.
    mapping(address=>uint256) public lastPollBlock;

    /// @notice mapping of terms that can be offboarded.
    mapping(address=>bool) public canOffboard;

    constructor(
        address _core,
        address _guildToken,
        uint256 _quorum
    ) CoreRef(_core) {
        guildToken = _guildToken;
        quorum = _quorum;
    }

    /// @notice set the quorum for offboard votes
    function setQuorum(uint256 _quorum) external onlyCoreRole(CoreRoles.GOVERNOR) {
        emit QuorumUpdated(quorum, _quorum);
        quorum = _quorum;
    }

    /// @notice Propose to offboard a given LendingTerm.
    /// @dev the poll starts with 1 wei of voting power, to initialize the storage slot
    /// that counts the number of user supports (a value of 0 is used as the existence
    /// check to know if a poll has been created).
    function proposeOffboard(address term) external whenNotPaused {
        require(polls[block.number][term] == 0, "LendingTermOffboarding: poll exists");
        require(block.number > lastPollBlock[term] + POLL_DURATION_BLOCKS, "LendingTermOffboarding: poll active");

        polls[block.number][term] = 1; // voting power
        lastPollBlock[term] = block.number;
        emit OffboardSupport(address(0), term, block.number, 1);
    }

    /// @notice Support a poll to offboard a given LendingTerm.
    function supportOffboard(uint256 snapshotBlock, address term) external whenNotPaused {
        require(block.number <= snapshotBlock + POLL_DURATION_BLOCKS, "LendingTermOffboarding: poll expired");
        uint256 _weight = polls[snapshotBlock][term];
        require(_weight != 0, "LendingTermOffboarding: poll not found");
        uint256 userWeight = GuildToken(guildToken).getPastVotes(msg.sender, snapshotBlock);
        require(userWeight != 0, "LendingTermOffboarding: zero weight");

        polls[snapshotBlock][term] = _weight + userWeight;
        if (_weight + userWeight >= quorum) {
            canOffboard[term] = true;
        }
        emit OffboardSupport(msg.sender, term, snapshotBlock, userWeight);
    }
    
    /// @notice Offboard a LendingTerm. This will seize the collateral of all loans.
    /// @param term LendingTerm to offboard from the system.
    /// @param loanIds List of loans to seize (skip loan calling).
    function offboard(address term, bytes32[] memory loanIds) external whenNotPaused {
        require(canOffboard[term], "LendingTermOffboarding: quorum not met");

        bool[] memory skipCall = new bool[](loanIds.length);
        for (uint256 i = 0; i < skipCall.length; i++) {
            skipCall[i] = true;
        }
        LendingTerm(term).setHardCap(0);
        LendingTerm(term).seizeMany(loanIds, skipCall);
        require(LendingTerm(term).issuance() == 0, "LendingTermOffboarding: not all loans closed");
        GuildToken(guildToken).removeGauge(term);

        canOffboard[term] = false;
        emit Offboard(term);
    }
}
