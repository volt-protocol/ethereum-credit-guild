import "IERC20.spec";

methods {
    function balanceOf(address) external returns (uint256) envfree;
    function delegatesVotesCount(address, address) external returns (uint256) envfree;
    function containsDelegate(address, address) external returns (bool) envfree;
    function totalSupply() external returns (uint256) envfree;
    /// EIP712 interface
    function eip712Domain() external returns 
        (bytes1,string memory,string memory,uint256,address,bytes32,uint256[] memory) =>
        NONDET DELETE(false); /// To prevent analysis errors

    function delegates(address) external returns (address[]) envfree;
    function userDelegatedVotes(address) external returns (uint256) envfree;
    function maxDelegates() external returns (uint256) envfree;
    function canContractExceedMaxDelegates(address) external returns (bool) envfree;
    function delegateCount(address) external returns (uint256) envfree;
}

// rule sanity(method f, env e) {
//     calldataarg args;

//     f(e, args);

//     assert false;
// }

/// @title A ghost to mirror the amounts delegated, needed for `sumDelegatedAmount`
ghost mapping(address => mapping(address => uint256)) delegatedAmountMirror {
    init_state axiom forall address a. forall address b. delegatedAmountMirror[a][b] == 0;
}

ghost mapping(address => mathint) sumDelegatedAmount {
    init_state axiom forall address a. sumDelegatedAmount[a] == 0;
    axiom forall address delegator. forall address a. forall address b. (
        (a == b => sumDelegatedAmount[delegator] >= to_mathint(delegatedAmountMirror[delegator][a])) &&
        (a == b => sumDelegatedAmount[delegator] >= to_mathint(delegatedAmountMirror[delegator][b])) &&
        (a != b => sumDelegatedAmount[delegator] >= delegatedAmountMirror[delegator][b] + delegatedAmountMirror[delegator][a])
    );
    axiom forall address delegator. forall address a. forall address b. forall address c. (
        (a != b && a != c && b != c) => 
        (sumDelegatedAmount[delegator] >= delegatedAmountMirror[delegator][a] + delegatedAmountMirror[delegator][b] + delegatedAmountMirror[delegator][c])
    );
}

hook Sstore _delegatesVotesCount[KEY address delegator][KEY address delegatee] uint256 newValue (uint256 oldValue) STORAGE {
    delegatedAmountMirror[delegator][delegatee] = newValue;
    sumDelegatedAmount[delegatee] = sumDelegatedAmount[delegatee] - oldValue + newValue;
}

/// ---------------- Balances Ghost ----------------

/// @title A ghost to mirror the balances, needed for `sumBalances`
ghost mapping(address => uint256) balanceOfMirror {
    init_state axiom forall address a. balanceOfMirror[a] == 0;
}

/** @title A ghost representing the sum of all balances
    @notice We require that it would be at least the sum of three balances, since that
    is what is needed in the `preserved` blocks.
    @notice We use the `balanceOfMirror` mirror here, since we are not allowed to call
    contract functions from a ghost.
*/
ghost mathint sumBalances {
    init_state axiom sumBalances == 0;
    axiom forall address a. forall address b. (
        (a == b => sumBalances >= to_mathint(balanceOfMirror[a])) &&
        (a != b => sumBalances >= balanceOfMirror[a] + balanceOfMirror[b])
    );
    axiom forall address a. forall address b. forall address c. (
        a != b && a != c && b != c => 
        sumBalances >= balanceOfMirror[a] + balanceOfMirror[b] + balanceOfMirror[c]
    );
}

// Because `balance` has a uint256 type, any balance addition in CVL1 behaved as a `require_uint256()` casting,
// leaving out the possibility of overflow. This is not the case in CVL2 where casting became more explicit.
// A counterexample in CVL2 is having an initial state where Alice initial balance is larger than totalSupply, which 
// overflows Alice's balance when receiving a transfer. This is not possible unless the contract is deployed into an 
// already used address (or upgraded from corrupted state).
// We restrict such behavior by making sure no balance is greater than the sum of balances.
hook Sload uint256 balance _balances[KEY address addr] STORAGE {
    require sumBalances >= to_mathint(balance);
}

hook Sstore _balances[KEY address addr] uint256 newValue (uint256 oldValue) STORAGE {
    sumBalances = sumBalances - oldValue + newValue;
    balanceOfMirror[addr] = newValue;
}

function getArrayLength(address user) returns uint256 {
    address[] array = delegates(user);

    return array.length;
}

/// assert sumDelegatedAmount ghost is correct
invariant sumDelegatedAmountEqUserDelegatedVotes(address user)
    sumDelegatedAmount[user] == to_mathint(userDelegatedVotes(user)) {
        preserved {
            requireInvariant mirrorIsTrue(user);
        }
        preserved delegate(address to) with (env e) {
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(user);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
        }
        preserved incrementDelegation(address to, uint256 amount) with (env e) {
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(user);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
        }
        preserved undelegate(address to, uint256 amount) with (env e) {
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(user);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
        }
        preserved delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) with (env e) {
            requireInvariant mirrorIsTrue(delegatee);
            requireInvariant mirrorIsTrue(user);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegatee);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
        }
        preserved transfer(address to, uint256 amount) with (env e) {
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(user);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
        }
        preserved transferFrom(address to, address from, uint256 amount) with (env e) {
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(from);
            requireInvariant mirrorIsTrue(user);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(from);
        }
    }

invariant mirrorEqualsValue(address delegator, address delegatee)
    delegatedAmountMirror[delegator][delegatee] == delegatesVotesCount(delegator, delegatee);

invariant sumDelegatedAmountLteTotalSupply(address user)
    sumDelegatedAmount[user] <= to_mathint(totalSupply()) {
        preserved {
            address a;
            requireInvariant totalIsSumBalances();
            requireInvariant totalSupplyIsSumOfBalances();
            requireInvariant userBalanceLteTotalSupply(user);
            requireInvariant userDelegatedVotesCountLteBalance(user);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(user);
            requireInvariant delegatesVotesCountLteUserDelegatedVotes(user, a);
        }
        preserved delegate(address to) with (env e) {
            requireInvariant totalSupplyIsSumOfBalances();
            requireInvariant totalIsSumBalances();
            requireInvariant userDelegatedVotesCountLteBalance(user);
            requireInvariant userBalanceLteTotalSupply(user);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(user);
            requireInvariant delegatesVotesCountCorrect(e.msg.sender, to);
            requireInvariant delegatesVotesCountLteUserDelegatedVotes(e.msg.sender, to);
        }
        preserved incrementDelegation(address to, uint256 amt) with (env e) {
            requireInvariant totalSupplyIsSumOfBalances();
            requireInvariant totalIsSumBalances();
            requireInvariant userDelegatedVotesCountLteBalance(user);
            requireInvariant userBalanceLteTotalSupply(user);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(user);
            requireInvariant delegatesVotesCountCorrect(e.msg.sender, to);
            requireInvariant delegatesVotesCountLteUserDelegatedVotes(e.msg.sender, to);
        }
        preserved delegateBySig(address to, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) with (env e) {
            requireInvariant totalSupplyIsSumOfBalances();
            requireInvariant totalIsSumBalances();
            requireInvariant userDelegatedVotesCountLteBalance(user);
            requireInvariant userBalanceLteTotalSupply(user);
            requireInvariant sumDelegatedAmountEqUserDelegatedVotes(user);
            requireInvariant delegatesVotesCountCorrect(e.msg.sender, to);
            requireInvariant delegatesVotesCountLteUserDelegatedVotes(e.msg.sender, to);
        }
    }

invariant delegatesVotesCountLteUserDelegatedVotes(address delegator, address delegatee)
    ((delegator != delegatee) && (delegatesVotesCount(delegator, delegatee) != 0)) =>
        delegatesVotesCount(delegator, delegatee) <= userDelegatedVotes(delegator) {
            preserved {
                requireInvariant userBalanceLteTotalSupply(delegatee);
                requireInvariant userBalanceLteTotalSupply(delegator);
                requireInvariant checkCvlLength(delegatee);
                requireInvariant checkCvlLength(delegator);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegatee);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegator);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegatee);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegator);
            }
            preserved delegate(address to) with (env e) {
                requireInvariant userBalanceLteTotalSupply(delegatee);
                requireInvariant userBalanceLteTotalSupply(delegator);
                requireInvariant userBalanceLteTotalSupply(to);
                requireInvariant userBalanceLteTotalSupply(e.msg.sender);
                requireInvariant checkCvlLength(to);
                requireInvariant checkCvlLength(delegatee);
                requireInvariant checkCvlLength(delegator);
                requireInvariant checkCvlLength(e.msg.sender);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegatee);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegator);
                requireInvariant sumDelegatedAmountLteTotalSupply(e.msg.sender);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegatee);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegator);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
                requireInvariant sumOfTwo(to, e.msg.sender);
            }
            preserved undelegate(address to, uint256 amt) with (env e) {
                requireInvariant userBalanceLteTotalSupply(delegatee);
                requireInvariant userBalanceLteTotalSupply(delegator);
                requireInvariant userBalanceLteTotalSupply(to);
                requireInvariant userBalanceLteTotalSupply(e.msg.sender);
                requireInvariant checkCvlLength(to);
                requireInvariant checkCvlLength(delegatee);
                requireInvariant checkCvlLength(delegator);
                requireInvariant checkCvlLength(e.msg.sender);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegatee);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegator);
                requireInvariant sumDelegatedAmountLteTotalSupply(e.msg.sender);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegatee);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegator);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
                requireInvariant sumOfTwo(to, e.msg.sender);
            }
            preserved delegateBySig(address to, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) with (env e) {
                requireInvariant userBalanceLteTotalSupply(delegatee);
                requireInvariant userBalanceLteTotalSupply(delegator);
                requireInvariant userBalanceLteTotalSupply(to);
                requireInvariant userBalanceLteTotalSupply(e.msg.sender);
                requireInvariant checkCvlLength(to);
                requireInvariant checkCvlLength(delegatee);
                requireInvariant checkCvlLength(delegator);
                requireInvariant checkCvlLength(e.msg.sender);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegatee);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegator);
                requireInvariant sumDelegatedAmountLteTotalSupply(e.msg.sender);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegatee);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegator);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
                requireInvariant sumOfTwo(to, e.msg.sender);
            }
            preserved transfer(address to, uint256 amt) with (env e) {
                requireInvariant sumOfTwo(to, e.msg.sender);
                requireInvariant userBalanceLteTotalSupply(delegatee);
                requireInvariant userBalanceLteTotalSupply(delegator);
                requireInvariant userBalanceLteTotalSupply(to);
                requireInvariant userBalanceLteTotalSupply(e.msg.sender);
                requireInvariant checkCvlLength(to);
                requireInvariant checkCvlLength(delegatee);
                requireInvariant checkCvlLength(delegator);
                requireInvariant checkCvlLength(e.msg.sender);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegatee);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegator);
                requireInvariant sumDelegatedAmountLteTotalSupply(e.msg.sender);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegatee);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegator);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(e.msg.sender);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
            }
            preserved transferFrom(address to, address from, uint256 amt) with (env e) {
                requireInvariant sumOfTwo(from, to);
                requireInvariant userBalanceLteTotalSupply(delegatee);
                requireInvariant userBalanceLteTotalSupply(delegator);
                requireInvariant userBalanceLteTotalSupply(to);
                requireInvariant userBalanceLteTotalSupply(from);
                requireInvariant userBalanceLteTotalSupply(e.msg.sender);
                requireInvariant checkCvlLength(to);
                requireInvariant checkCvlLength(from);
                requireInvariant checkCvlLength(delegatee);
                requireInvariant checkCvlLength(delegator);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegatee);
                requireInvariant sumDelegatedAmountLteTotalSupply(delegator);
                requireInvariant sumDelegatedAmountLteTotalSupply(to);
                requireInvariant sumDelegatedAmountLteTotalSupply(from);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegatee);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(delegator);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(to);
                requireInvariant sumDelegatedAmountEqUserDelegatedVotes(from);
            }
        }

invariant totalSupplyIsSumOfBalances()
    to_mathint(totalSupply()) == sumBalances;

invariant userBalanceLteTotalSupply(address user)
    totalSupply() >= balanceOf(user) {
        preserved {
            /// assert mirrors
            requireInvariant mirrorIsTrue(user);
            requireInvariant totalSupplyIsSumOfBalances();
            requireInvariant totalIsSumBalances();
        }
    }

invariant delegatesLteMaxDelegatesAmt(address user)
    getArrayLength(user) <= maxDelegates() || canContractExceedMaxDelegates(user);

invariant contractCannotExceedMaxDelegates(address user)
    !canContractExceedMaxDelegates(user) => getArrayLength(user) <= maxDelegates();

invariant checkCvlLength(address user)
    getArrayLength(user) == delegateCount(user);

/// if user a has delegated to user b, then a must contain delegate b (invalid state)
/// ensure either user does not have more delegatesVotesCountCorrect than balance (invalid state)
/// user delegate counts must sum the length of the array of their delegates (invalid state)
invariant delegatesVotesCountCorrect(address delegator, address delegatee)
    (((delegatesVotesCount(delegator, delegatee) != 0)) => (containsDelegate(delegator, delegatee))) &&
    ((delegatesVotesCount(delegatee, delegator) != 0) => containsDelegate(delegatee, delegator)) {
        preserved {
            /// user cannot have delegated more votes than their balance
            requireInvariant userDelegatesVotesCount(delegator, delegatee);
            requireInvariant userDelegatesVotesCount(delegatee, delegator);
            /// user cannot have delegated to more than max 
            requireInvariant delegatesLteMaxDelegatesAmt(delegatee);
            requireInvariant delegatesLteMaxDelegatesAmt(delegator);
            /// user delegate counts must add up
            requireInvariant checkCvlLength(delegatee);
            requireInvariant checkCvlLength(delegator);
        }
    }

invariant userDelegatedVotesCountLteBalance(address delegator)
    balanceOf(delegator) >= userDelegatedVotes(delegator) {
        preserved {
            address delegatee;

            requireInvariant userDelegatesVotesCount(delegator, delegatee);
            requireInvariant checkCvlLength(delegator);
            /// total supply check
            requireInvariant totalIsSumBalances();
            /// balance checks
            requireInvariant mirrorIsTrue(delegator);
            requireInvariant userBalanceLteTotalSupply(delegator);
        }
        preserved delegate(address to) with (env e) {
            requireInvariant userDelegatesVotesCount(e.msg.sender, to);
            requireInvariant checkCvlLength(delegator);
            requireInvariant checkCvlLength(to);
            requireInvariant checkCvlLength(e.msg.sender);
            /// total supply check
            requireInvariant totalIsSumBalances();
            /// balance checks
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(delegator);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant userBalanceLteTotalSupply(to);
            requireInvariant userBalanceLteTotalSupply(delegator);
            requireInvariant userBalanceLteTotalSupply(e.msg.sender);
        }
        preserved transfer(address to, uint256 amt) with (env e) {
            requireInvariant userDelegatesVotesCount(e.msg.sender, to);
            requireInvariant checkCvlLength(delegator);
            requireInvariant checkCvlLength(to);
            requireInvariant checkCvlLength(e.msg.sender);
            /// total supply check
            requireInvariant totalIsSumBalances();
            /// balance checks
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(delegator);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant userBalanceLteTotalSupply(to);
            requireInvariant userBalanceLteTotalSupply(delegator);
            requireInvariant userBalanceLteTotalSupply(e.msg.sender);
        }
        preserved transferFrom(address to, address from, uint256 amt) with (env e) {
            requireInvariant userDelegatesVotesCount(to, from);
            requireInvariant checkCvlLength(delegator);
            requireInvariant checkCvlLength(to);
            requireInvariant checkCvlLength(from);
            requireInvariant checkCvlLength(e.msg.sender);
            /// total supply check
            requireInvariant totalIsSumBalances();
            /// balance checks
            requireInvariant mirrorIsTrue(from);
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(delegator);
            requireInvariant mirrorIsTrue(e.msg.sender);
            requireInvariant userBalanceLteTotalSupply(to);
            requireInvariant userBalanceLteTotalSupply(delegator);
            requireInvariant userBalanceLteTotalSupply(e.msg.sender);
        }
    }

/// user delegated votes 
invariant userDelegatesVotesCount(address delegator, address delegatee)
    balanceOf(delegator) >= delegatesVotesCount(delegator, delegatee) {
        preserved {
            /// checks cvl length
            /// checks delegates lte max delegates amt
            /// checks user delegated votes lte balance
            requireInvariant delegatesVotesCountCorrect(delegator, delegatee);
            /// ensure user has not delegated more votes than balance
            requireInvariant userDelegatedVotesCountLteBalance(delegator);
            requireInvariant userDelegatedVotesCountLteBalance(delegatee);
        }
        preserved delegate(address to) with (env e) {
            requireInvariant delegatesVotesCountCorrect(delegator, delegatee);
            /// ensure user has not delegated more votes than balance
            requireInvariant userDelegatedVotesCountLteBalance(delegator);
            requireInvariant userDelegatedVotesCountLteBalance(delegatee);
            requireInvariant delegatesVotesCountCorrect(delegator, delegatee);
            requireInvariant userDelegatesVotesCount(e.msg.sender, to);
            /// ensure user has not delegated more votes than balance
            requireInvariant userDelegatedVotesCountLteBalance(to);
            requireInvariant userDelegatedVotesCountLteBalance(e.msg.sender);
            requireInvariant sumOfTwo(e.msg.sender, to);
        }
        preserved transfer(address to, uint256 amount) with (env e) {
            requireInvariant delegatesVotesCountCorrect(delegator, delegatee);
            /// ensure user has not delegated more votes than balance
            requireInvariant userDelegatedVotesCountLteBalance(delegator);
            requireInvariant userDelegatedVotesCountLteBalance(delegatee);
            requireInvariant delegatesVotesCountCorrect(delegator, delegatee);
            requireInvariant userDelegatesVotesCount(e.msg.sender, to);
            /// ensure user has not delegated more votes than balance
            requireInvariant userDelegatedVotesCountLteBalance(e.msg.sender);
            requireInvariant sumOfTwo(e.msg.sender, to);
        }
        preserved transferFrom(address to, address from, uint256 amount) with (env e) {
            requireInvariant delegatesVotesCountCorrect(delegator, delegatee);
            /// ensure user has not delegated more votes than balance
            requireInvariant userDelegatedVotesCountLteBalance(delegator);
            requireInvariant userDelegatedVotesCountLteBalance(delegatee);
            requireInvariant sumOfTwo(from, to); /// balances lte total supply ghost
            requireInvariant userDelegatesVotesCount(to, from);

            requireInvariant userDelegatedVotesCountLteBalance(to);
            requireInvariant userDelegatedVotesCountLteBalance(from);
        }
    }

invariant userBalancesLteUintMax(address a, address b)
    (a != b) => ((balanceOf(a) + balanceOf(b)) <= max_uint256) {
        preserved {
            requireInvariant totalIsSumBalances();
            requireInvariant totalSupplyIsSumOfBalances();
            requireInvariant mirrorIsTrue(a);
            requireInvariant mirrorIsTrue(b);
            requireInvariant sumOfTwo(a, b);
        }
        preserved transfer(address to, uint256 amount) with (env e1) {
            requireInvariant totalIsSumBalances();
            requireInvariant totalSupplyIsSumOfBalances();
            requireInvariant mirrorIsTrue(a);
            requireInvariant mirrorIsTrue(b);
            requireInvariant sumOfTwo(a, b);
            requireInvariant sumOfTwo(a, e1.msg.sender);
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(e1.msg.sender);
        }
        preserved transferFrom(address to, address from, uint256 amount) with (env e1) {
            requireInvariant totalIsSumBalances();
            requireInvariant totalSupplyIsSumOfBalances();
            requireInvariant mirrorIsTrue(a);
            requireInvariant mirrorIsTrue(b);
            requireInvariant sumOfTwo(a, b);
            requireInvariant sumOfTwo(to, from);
            requireInvariant mirrorIsTrue(from);
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(from);
            requireInvariant mirrorIsTrue(e1.msg.sender);
        }
    }

/// @title Formally prove that `balanceOfMirror` mirrors `balanceOf`
invariant mirrorIsTrue(address a)
    balanceOfMirror[a] == balanceOf(a) {
        preserved transfer(address to, uint256 amount) with (env e1) {
            requireInvariant userBalancesLteUintMax(to, e1.msg.sender);
            requireInvariant userBalancesLteUintMax(a, e1.msg.sender);
        }
        preserved transferFrom(address to, address from, uint256 amount) with (env e1) {
            requireInvariant userBalancesLteUintMax(to, a);
            requireInvariant userBalancesLteUintMax(to, e1.msg.sender);
            requireInvariant userBalancesLteUintMax(a, e1.msg.sender);
        }
    }

/// @title Proves that `totalSupply` is `sumBalances`
invariant totalIsSumBalances()
    to_mathint(totalSupply()) == sumBalances
    {
        preserved transfer(address to, uint256 amount) with (env e1) {
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(e1.msg.sender);
        }
        preserved transferFrom(address from, address to, uint256 amount) with (env e2) {
            requireInvariant mirrorIsTrue(from);
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(e2.msg.sender);
        }
    }

invariant sumOfTwo(address a, address b)
    (a != b) => (balanceOf(a) + balanceOf(b) <= sumBalances) {
        preserved {
            requireInvariant mirrorIsTrue(a);
            requireInvariant mirrorIsTrue(b);
            requireInvariant totalIsSumBalances();
        }
        preserved transfer(address to, uint256 amt) with (env e) {
            requireInvariant mirrorIsTrue(a);
            requireInvariant mirrorIsTrue(b);
            requireInvariant totalIsSumBalances();
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(e.msg.sender);
        }
        preserved transferFrom(address from, address to, uint256 amount) with (env e2) {
            requireInvariant mirrorIsTrue(a);
            requireInvariant mirrorIsTrue(b);
            requireInvariant totalIsSumBalances();
            requireInvariant mirrorIsTrue(to);
            requireInvariant mirrorIsTrue(from);
            requireInvariant mirrorIsTrue(e2.msg.sender);
        }
    }
