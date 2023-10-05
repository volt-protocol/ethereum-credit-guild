/* 
   Verification of an ERC20 - proving totalSupply is the sum of all balances
   
   NOTE: We only use invariants and `requireInvariant` here, so we are sound.
*/

methods {
    function balanceOf(address) external returns (uint256) envfree;
    function totalSupply() external returns (uint256) envfree;
}

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

/// @title The hook
hook Sstore _balances[KEY address user] uint256 new_balance (uint256 old_balance) STORAGE
{
    sumBalances = sumBalances + new_balance - old_balance;
    balanceOfMirror[user] = new_balance;
}

/// @title Formally prove that `balanceOfMirror` mirrors `balanceOf`
invariant mirrorIsTrue(address a)
    balanceOfMirror[a] == balanceOf(a);

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
