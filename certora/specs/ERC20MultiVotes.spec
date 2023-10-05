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

invariant mirrorEqualsValue(address delegator, address delegatee)
    delegatedAmountMirror[delegator][delegatee] == delegatesVotesCount(delegator, delegatee);

invariant sumDelegatedAmountLteBalance(address user)
    sumDelegatedAmount[user] <= to_mathint(balanceOf(user));

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



invariant totalSupplyIsSumOfBalances()
    to_mathint(totalSupply()) == sumBalances;

invariant delegatesLteMaxDelegatesAmt(address user)
    getArrayLength(user) <= maxDelegates() || canContractExceedMaxDelegates(user);

invariant contractCannotExceedMaxDelegates(address user)
    !canContractExceedMaxDelegates(user) => getArrayLength(user) <= maxDelegates();

invariant checkCvlLength(address user)
    getArrayLength(user) == delegateCount(user);

invariant delegatesVotesCount(address delegator, address delegatee)
    (((delegatesVotesCount(delegator, delegatee) != 0)) => (containsDelegate(delegator, delegatee))) &&
    ((delegatesVotesCount(delegatee, delegator) != 0) => containsDelegate(delegatee, delegator));

invariant userDelegatedVotesLteBalance(address delegator, address delegatee)
    balanceOf(delegator) >= delegatesVotesCount(delegator, delegatee);

invariant userBalancesLteUintMax(address a, address b)
    (balanceOf(a) + balanceOf(b)) <= max_uint256;

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
