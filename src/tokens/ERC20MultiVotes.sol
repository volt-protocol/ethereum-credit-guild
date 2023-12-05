// SPDX-License-Identifier: MIT
// Voting logic inspired by OpenZeppelin Contracts v4.4.1 (token/ERC20/extensions/ERC20Votes.sol)

pragma solidity 0.8.13;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {SafeCastLib} from "@src/external/solmate/SafeCastLib.sol";

/**
@title  ERC20 Multi-Delegation Voting contract
@notice an ERC20 extension which allows delegations to multiple delegatees up to a user's balance on a given block.
@dev    SECURITY NOTES: `maxDelegates` is a critical variable to protect against gas DOS attacks upon token transfer. 
        This must be low enough to allow complicated transactions to fit in a block.
@dev This contract was originally published as part of TribeDAO's flywheel-v2 repo, please see:
    https://github.com/fei-protocol/flywheel-v2/blob/main/src/token/ERC20MultiVotes.sol
    The original version was included in 2 audits :
    - https://code4rena.com/reports/2022-04-xtribe/
    - https://consensys.net/diligence/audits/2022/04/tribe-dao-flywheel-v2-xtribe-xerc4626/
    ECG made the following changes to the original flywheel-v2 version :
    - Does not inherit Solmate's Auth (all requiresAuth functions are now internal, see below)
        -> This contract is abstract, and permissioned public functions can be added in parent.
        -> permissioned public functions to add in parent:
            - function setMaxDelegates(uint256) external
            - function setContractExceedMaxDelegates(address,bool) external
    - Remove public setMaxDelegates(uint256) requiresAuth method 
        ... Add internal _setMaxDelegates(uint256) method
    - Remove public setContractExceedMaxDelegates(address,bool) requiresAuth method
        ... Add internal _setContractExceedMaxDelegates(address,bool) method
    - Import OpenZeppelin ERC20Permit & EnumerableSet instead of Solmate's
    - Update error management style (use require + messages instead of Solidity errors)
    - Implement C4 audit fix for [L-01] & [N-06].
*/
abstract contract ERC20MultiVotes is ERC20Permit {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCastLib for *;

    /*///////////////////////////////////////////////////////////////
                        VOTE CALCULATION LOGIC
    //////////////////////////////////////////////////////////////*/

    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    /// @notice votes checkpoint list per user.
    mapping(address => Checkpoint[]) private _checkpoints;

    /// @notice Get the `pos`-th checkpoint for `account`.
    function checkpoints(
        address account,
        uint32 pos
    ) public view virtual returns (Checkpoint memory) {
        return _checkpoints[account][pos];
    }

    /// @notice Get number of checkpoints for `account`.
    function numCheckpoints(
        address account
    ) public view virtual returns (uint32) {
        return _checkpoints[account].length.safeCastTo32();
    }

    /**
     * @notice Gets the amount of unallocated votes for `account`.
     * @param account the address to get free votes of.
     * @return the amount of unallocated votes.
     */
    function freeVotes(address account) public view virtual returns (uint256) {
        return balanceOf(account) - userDelegatedVotes[account];
    }

    /**
     * @notice Gets the current votes balance for `account`.
     * @param account the address to get votes of.
     * @return the amount of votes.
     */
    function getVotes(address account) public view virtual returns (uint256) {
        uint256 pos = _checkpoints[account].length;
        return pos == 0 ? 0 : _checkpoints[account][pos - 1].votes;
    }

    /**
     * @notice Retrieve the number of votes for `account` at the end of `blockNumber`.
     * @param account the address to get votes of.
     * @param blockNumber the block to calculate votes for.
     * @return the amount of votes.
     */
    function getPastVotes(
        address account,
        uint256 blockNumber
    ) public view virtual returns (uint256) {
        require(
            blockNumber < block.number,
            "ERC20MultiVotes: not a past block"
        );
        return _checkpointsLookup(_checkpoints[account], blockNumber);
    }

    /// @dev Lookup a value in a list of (sorted) checkpoints.
    function _checkpointsLookup(
        Checkpoint[] storage ckpts,
        uint256 blockNumber
    ) private view returns (uint256) {
        // We run a binary search to look for the earliest checkpoint taken after `blockNumber`.
        uint256 high = ckpts.length;
        uint256 low = 0;
        while (low < high) {
            uint256 mid = average(low, high);
            if (ckpts[mid].fromBlock > blockNumber) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return high == 0 ? 0 : ckpts[high - 1].votes;
    }

    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /*///////////////////////////////////////////////////////////////
                        ADMIN OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice emitted when updating the maximum amount of delegates per user
    event MaxDelegatesUpdate(uint256 oldMaxDelegates, uint256 newMaxDelegates);

    /// @notice emitted when updating the canContractExceedMaxDelegates flag for an account
    event CanContractExceedMaxDelegatesUpdate(
        address indexed account,
        bool canContractExceedMaxDelegates
    );

    /// @notice the maximum amount of delegates for a user at a given time
    uint256 public maxDelegates;

    /// @notice an approve list for contracts to go above the max delegate limit.
    mapping(address => bool) public canContractExceedMaxDelegates;

    /// @notice set the new max delegates per user. Requires auth by `authority`.
    function _setMaxDelegates(uint256 newMax) internal {
        uint256 oldMax = maxDelegates;
        maxDelegates = newMax;

        emit MaxDelegatesUpdate(oldMax, newMax);
    }

    /// @notice set the canContractExceedMaxDelegates flag for an account.
    function _setContractExceedMaxDelegates(
        address account,
        bool canExceedMax
    ) internal {
        require(
            !canExceedMax || account.code.length != 0,
            "ERC20MultiVotes: not a smart contract"
        ); // can only approve contracts

        canContractExceedMaxDelegates[account] = canExceedMax;

        emit CanContractExceedMaxDelegatesUpdate(account, canExceedMax);
    }

    /*///////////////////////////////////////////////////////////////
                        DELEGATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when a `delegator` delegates `amount` votes to `delegate`.
    event Delegation(
        address indexed delegator,
        address indexed delegate,
        uint256 amount
    );

    /// @dev Emitted when a `delegator` undelegates `amount` votes from `delegate`.
    event Undelegation(
        address indexed delegator,
        address indexed delegate,
        uint256 amount
    );

    /// @dev Emitted when a token transfer or delegate change results in changes to an account's voting power.
    event DelegateVotesChanged(
        address indexed delegate,
        uint256 previousBalance,
        uint256 newBalance
    );

    /// @notice An event that is emitted when an account changes its delegate
    /// @dev this is used for backward compatibility with OZ interfaces for ERC20Votes and ERC20VotesComp.
    event DelegateChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );

    /// @notice mapping from a delegator and delegatee to the delegated amount.
    mapping(address => mapping(address => uint256))
        private _delegatesVotesCount;

    /// @notice mapping from a delegator to the total number of delegated votes.
    mapping(address => uint256) public userDelegatedVotes;

    /// @notice list of delegates per user.
    mapping(address => EnumerableSet.AddressSet) private _delegates;

    /**
     * @notice Get the amount of votes currently delegated by `delegator` to `delegatee`.
     * @param delegator the account which is delegating votes to `delegatee`.
     * @param delegatee the account receiving votes from `delegator`.
     * @return the total amount of votes delegated to `delegatee` by `delegator`
     */
    function delegatesVotesCount(
        address delegator,
        address delegatee
    ) public view virtual returns (uint256) {
        return _delegatesVotesCount[delegator][delegatee];
    }

    /**
     * @notice Get the list of delegates from `delegator`.
     * @param delegator the account which is delegating votes to delegates.
     * @return the list of delegated accounts.
     */
    function delegates(
        address delegator
    ) public view returns (address[] memory) {
        return _delegates[delegator].values();
    }

    /**
     * @notice Checks whether delegatee is in the `delegator` mapping.
     * @param delegator the account which is delegating votes to delegates.
     * @param delegatee the account which receives votes from delegate.
     * @return true or false
     */
    function containsDelegate(
        address delegator,
        address delegatee
    ) public view returns (bool) {
        return _delegates[delegator].contains(delegatee);
    }

    /**
     * @notice Get the number of delegates from `delegator`.
     * @param delegator the account which is delegating votes to delegates.
     * @return the number of delegated accounts.
     */
    function delegateCount(address delegator) public view returns (uint256) {
        return _delegates[delegator].length();
    }

    /**
     * @notice Delegate `amount` votes from the sender to `delegatee`.
     * @param delegatee the receiver of votes.
     * @param amount the amount of votes received.
     * @dev requires "freeVotes(msg.sender) > amount" and will not exceed max delegates
     */
    function incrementDelegation(
        address delegatee,
        uint256 amount
    ) public virtual {
        _incrementDelegation(msg.sender, delegatee, amount);
    }

    /**
     * @notice Undelegate `amount` votes from the sender from `delegatee`.
     * @param delegatee the receivier of undelegation.
     * @param amount the amount of votes taken away.
     */
    function undelegate(address delegatee, uint256 amount) public virtual {
        _undelegate(msg.sender, delegatee, amount);
    }

    /**
     * @notice Delegate all votes `newDelegatee`. First undelegates from an existing delegate. If `newDelegatee` is zero, only undelegates.
     * @param newDelegatee the receiver of votes.
     * @dev undefined for `delegateCount(msg.sender) > 1`
     * NOTE This is meant for backward compatibility with the `ERC20Votes` and `ERC20VotesComp` interfaces from OpenZeppelin.
     */
    function delegate(address newDelegatee) external virtual {
        _delegate(msg.sender, newDelegatee);
    }

    function _delegate(
        address delegator,
        address newDelegatee
    ) internal virtual {
        uint256 count = delegateCount(delegator);

        // undefined behavior for delegateCount > 1
        require(count < 2, "ERC20MultiVotes: delegation error");

        address oldDelegatee;
        // if already delegated, undelegate first
        if (count == 1) {
            oldDelegatee = _delegates[delegator].at(0);
            _undelegate(
                delegator,
                oldDelegatee,
                _delegatesVotesCount[delegator][oldDelegatee]
            );
        }

        // redelegate only if newDelegatee is not empty
        if (newDelegatee != address(0)) {
            _incrementDelegation(delegator, newDelegatee, freeVotes(delegator));
        }
        emit DelegateChanged(delegator, oldDelegatee, newDelegatee);
    }

    function _incrementDelegation(
        address delegator,
        address delegatee,
        uint256 amount
    ) internal virtual {
        // Require freeVotes exceed the delegation size
        uint256 free = freeVotes(delegator);
        require(
            delegatee != address(0) && free >= amount,
            "ERC20MultiVotes: delegation error"
        );

        bool newDelegate = _delegates[delegator].add(delegatee); // idempotent add
        require(
            !newDelegate ||
                delegateCount(delegator) <= maxDelegates ||
                canContractExceedMaxDelegates[delegator],
            "ERC20MultiVotes: delegation error"
        );

        _delegatesVotesCount[delegator][delegatee] += amount;
        userDelegatedVotes[delegator] += amount;

        emit Delegation(delegator, delegatee, amount);
        _writeCheckpoint(delegatee, _add, amount);
    }

    function _undelegate(
        address delegator,
        address delegatee,
        uint256 amount
    ) internal virtual {
        uint256 newDelegates = _delegatesVotesCount[delegator][delegatee] -
            amount;

        if (newDelegates == 0) {
            require(_delegates[delegator].remove(delegatee));
        }

        _delegatesVotesCount[delegator][delegatee] = newDelegates;
        userDelegatedVotes[delegator] -= amount;

        emit Undelegation(delegator, delegatee, amount);
        _writeCheckpoint(delegatee, _subtract, amount);
    }

    function _writeCheckpoint(
        address delegatee,
        function(uint256, uint256) view returns (uint256) op,
        uint256 delta
    ) private {
        Checkpoint[] storage ckpts = _checkpoints[delegatee];

        uint256 pos = ckpts.length;
        uint256 oldWeight = pos == 0 ? 0 : ckpts[pos - 1].votes;
        uint256 newWeight = op(oldWeight, delta);

        if (pos > 0 && ckpts[pos - 1].fromBlock == block.number) {
            ckpts[pos - 1].votes = newWeight.safeCastTo224();
        } else {
            ckpts.push(
                Checkpoint({
                    fromBlock: block.number.safeCastTo32(),
                    votes: newWeight.safeCastTo224()
                })
            );
        }
        emit DelegateVotesChanged(delegatee, oldWeight, newWeight);
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256) {
        return a + b;
    }

    function _subtract(uint256 a, uint256 b) private pure returns (uint256) {
        return a - b;
    }

    /*///////////////////////////////////////////////////////////////
                             ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// NOTE: any "removal" of tokens from a user requires freeVotes(user) < amount.
    /// _decrementVotesUntilFree is called as a greedy algorithm to free up votes.
    /// It may be more gas efficient to free weight before burning or transferring tokens.

    function _burn(address from, uint256 amount) internal virtual override {
        _decrementVotesUntilFree(from, amount);
        super._burn(from, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        _decrementVotesUntilFree(msg.sender, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        _decrementVotesUntilFree(from, amount);
        return super.transferFrom(from, to, amount);
    }

    /// a greedy algorithm for freeing votes before a token burn/transfer
    /// frees up entire delegates, so likely will free more than `votes`
    function _decrementVotesUntilFree(address user, uint256 votes) internal {
        uint256 userFreeVotes = freeVotes(user);

        // early return if already free
        if (userFreeVotes >= votes) return;

        // cache total for batch updates
        uint256 totalFreed;

        // Loop through all delegates
        address[] memory delegateList = _delegates[user].values();

        // Free delegates until through entire list or under votes amount
        uint256 size = delegateList.length;
        for (
            uint256 i = 0;
            i < size && (userFreeVotes + totalFreed) < votes;
            i++
        ) {
            address delegatee = delegateList[i];
            uint256 delegateVotes = _delegatesVotesCount[user][delegatee];
            if (delegateVotes != 0) {
                totalFreed += delegateVotes;

                require(_delegates[user].remove(delegatee)); // Remove from set. Should never fail.

                _delegatesVotesCount[user][delegatee] = 0;

                _writeCheckpoint(delegatee, _subtract, delegateVotes);
                emit Undelegation(user, delegatee, delegateVotes);
            }
        }

        userDelegatedVotes[user] -= totalFreed;
    }

    /*///////////////////////////////////////////////////////////////
                             EIP-712 LOGIC
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @dev this consumes the same nonce as permit(), so the order of call matters.
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(
            block.timestamp <= expiry,
            "ERC20MultiVotes: signature expired"
        );
        address signer = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    _domainSeparatorV4(),
                    keccak256(
                        abi.encode(
                            DELEGATION_TYPEHASH,
                            delegatee,
                            nonce,
                            expiry
                        )
                    )
                )
            ),
            v,
            r,
            s
        );
        require(nonce == _useNonce(signer), "ERC20MultiVotes: invalid nonce");
        require(signer != address(0));
        _delegate(signer, delegatee);
    }
}
