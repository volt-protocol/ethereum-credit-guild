# Ethereum Credit Guild

The **credit** is a decentralized debt based stablecoin, which can follow an arbitrary monetary policy, but we will assume attempts to maintain stability or strength relative to major currencies, particularly the dollar, while appreciating via a floating interest income. Due to fluctuations in the value of the underlying loan book based on market rate volatility, precise price stability in regards to a reference asset cannot be guaranteed.

There exist two tokens in the system, CREDIT, and GUILD.

A GUILD holder with above a minimum threshold of the token supply can propose a new set of lending terms.

```
// propose a new set of lending terms to governance

// require that the caller stakes at least X% of GUILD supply

// inputs:
  * address of the collateral token
  * number of credits mintable per collateral token
  * interest rate in terms of credits per block
  * how long this loan term is available in blocks
  * call fee in credits
  * number of GUILD tokens to stake on the proposal

// stores the terms in a mapping uint256=>terms

function propose(address collateral, uint256 maxCreditsPerCollateralToken, uint256 interestRate, uint256 termDuration, uint256 callFee, uint votingAmount) {
    ...
}
```

There is a period during which other GUILD holders can dispute the loan terms. If the loan terms are *denied*, the proposer pays a small fee in GUILD. If not denied, they optimistically become available for GUILD holders to vote for in the debt limit allocation.

```
function deny(uint256 terms) {
    ...
}
```

If not denied during the dispute window, any GUILD holder can vote for that loan term to increase its debt ceiling (whoever proposed it is voting for it by default, so the starting debt ceiling will be at the proposal threshold until users allocate away).

```
function vote(uint256 terms, uint256 amountToStake) {
    ...
}
```

The debt ceiling of a given loan is determined based on the amount of GUILD staked to it, and the protocol's currently allowed leverage ratio. For example, if the max global leverage is 20x, and the surplus buffer is 1m CREDIT, then there is a global debt ceiling of 20m CREDIT. A holder of 10% of the GUILD supply can thus allocate a debt ceiling of 2m CREDIT.

To initiate a loan, a user must first post collateral. Deposit can occur at any time; withdraw requires there are no active loans against the collateral in question.

```
function post(address collateralToken, uint256 amount) {
    ...
}
```

If there is a loan term that accepts their collateral asset with an available debt ceiling, they can then initiate a loan.

```
function mintAsDebt(uint256 terms, uint256 amountCollateralIn, uint256 amountToMint) {
    ...
}
```

The user can mint up to the maximum amount allowed by the loan terms, with their collateral locked and unavailable for transfer or use in other loans until the loan is repaid.

The protocol checks that the requested mint amount and collateral provided conform to the available terms, and if so, the user can mint CREDIT.

When a user repays their loan, they must repay a greater amount of CREDIT than they borrowed due to the accrued interest. The initial loan amount is burnt, while the profits go to the surplus buffer.

If the system is otherwise in equilibrium (no change in demand to hold or borrow credits) then the value of credits will tend to increase over time as the surplus buffer accumulates credits. Based on the internal rate of return, the current value of a credit will fluctuate on the market.

An GUILD holder can burn their tokens for a pro rata share of the system surplus (likely with some fee) so long as this does not push the system below a minimum reserve ratio (ie, 5%), and at a maximum rate of X tokens burnt per period such that this mechanism cannot destabilize the CREDIT price.

In this way, **the interest rate on CREDIT is determined entirely through a decentralized market process**. If GUILD holders want to prioritize growth, they can accumulate capital in the surplus buffer, which drives up the CREDIT price. If they want to take profits, they can do so by burning their tokens in exchange for CREDIT, effectively reducing the yield paid out to credit holders.

Anyone can call a loan issued by the protocol by paying the call fee in either credits or GUILD. If the position's debt is larger than the `maxCreditsPerCollateralToken` defined in the loan's terms, which can only occur due to accrued interest, the call fee is waived. Otherwise, the call fee is deducted from the borrower's debt and burnt. A liquidation auction occurs to repay as much as possible of the borrower's debt by selling off as little as possible of the collateral position. If the auction reveals the loan to be insolvent, the one who triggered the auction is rewarded by being reimbursed the call fee if one was paid plus a liquidation reward. If the loan was insolvent, any GUILD holders voting for that loan's terms have their balances slashed, and the CREDIT that was lost is deducted from the surplus buffer.

It is possible for the surplus buffer balance to become negative if a loss exceeds the buffer's starting balance. In this case, a GUILD auction is triggered, diluting the existing GUILD holders in an attempt to recapitalize the system. If this auction is insufficient to fully recapitalize the protocol, the surplus buffer is zero'd out. The goal of this mechanism is to 1) minimize any possible loss to the CREDIT holders and 2) fairly distribute any loss that does occur.

GUILD holders have both an individual incentive to avoid being liquidated, and a collective incentive to prevent excessive risk taking. They earn rewards proportional to the yield they generate, and thus an honest GUILD holder will pursue the highest +EV yield opportunity available to them, while preventing others from taking risk that will create a loss larger than that individual's pro rata share of the surplus buffer.

So long as there is an honest minority of GUILD holders, reckless loans that endanger the system as a whole can be prevented, while the loans that do fail result in a decreased ownership stake for bad allocators.




## Example Market Behavior

Suppose that one credit starts at a price of one dollar.

If there is net demand to hold credits, the price will drift up, say to $1.01. From the perspective of existing borrowers, it has become more expensive to repay their debts. From the perspective of existing credit holders, it is a bonus interest income that they could realize by selling their credits. From the perspective of a new borrower, it is a chance to earn an arbitrage income **if this demand is temporary and the price is expected to revert**. It's impossible to predict with certainty whether this is the case. MakerDAO implemented a zero fee USDC PSM (which is being altered after this weekend's peg scare) to ensure a smooth arbitrage loop between DAI and the dollar. CREDIT takes a different approach in rejecting trust in any external asset as being exactly equal to $1, and furthermore, accepting some noise in CREDIT's peg rather than admitting bank run/Gresham's law risk with a naive PSM.

Consider a credit with two basic types of loan terms available:

- long term availability loans, expected to need to be altered by governance only rarely and thus having a long availability duration, perhaps one month. For example, "mint 100 CREDIT against 102 USDC at 1% interest and 1% call fee" creates a robust arbitrage opportunity for maintaining CREDIT price stability, while protecting the protocol from an event like a single partner bank of Circle failing.
- short term availability loans, mostly for volatile assets that need to be rolled over frequently and thus have a short availability duration for a given loan term, perhaps a week. For example, "mint 1000 CREDIT against 1 ETH at 1% interest and 0.5% call fee". In a week, this might be too close to the current ETH price for lenders to approve issuing new loans.

If there is a spike in demand to hold CREDIT vs to long CREDIT/ETH, an arbitrageur can profit by minting CREDIT against USDC. At $1.02+ per CREDIT, the arbitrageur has risk-free profit, constraining the price borrowers must face to close their positions within a reasonable bound. What if the arbitrageur loses their bet, and the CREDIT price increases further during their loan term? Given the call fee on the loan, they have until the interest they're charged accumulates enough to make 