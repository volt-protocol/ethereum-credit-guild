17 April 2023

I've been considering mechanisms by which GUILD holders can lend at longer durations safely. The first that came to mind was credit token denominations based on the maximum call time or call fee for the underlying loans, but this makes pricing more difficult and fragments liquidity.

Erwan had what I think is a better idea, which is applying the callable loan mechanism more directly to credit lockups. The version of this I've worked out is roughly as follows:

Use a special type of LendingTerm which we can call a CreditBond where borrowing occurs via a special BondBorrow contract and the protocol is the only borrower. This can be combined with a regular loan into a strategy such that credits are borrowed from the credit bond, and lend in an ordinary lending term.

A more tangible example:

Consider a CreditBond A offering these terms:

* 2% interest on top of the base CREDIT rate
* 1 month call period
* 50 bips call fee

And a regular lending term B such as:

* collateral token OP
* interest rate 10%
* call fee 1%
* call period 3 months

A GUILD holder in the gauges might then vote for a strategy like "borrow CREDIT under terms A, and lend it under terms B". The CREDIT holders who vote for A don't need to decide which terms the rehypothecation occurs under, only their own liquidity preferences. This is reasonably simple while allowing some more expressiveness on the maturity side.


7 April 2023

Notes on removal of surplus buffer redemption:

Multiple credit denominations introduces a challenge to surplus buffer accounting. If losses are taken in one credit token, is the surplus buffer held in common, or only a certain share available? Does the yield from a given credit token accrue only to its individual surplus buffer, or to a common pool? What happens in the event of bad debt?

On a related note, we've been discussing the question of surplus buffer allocation. Allowing the surplus to accumulate in the native debt asset will drive up the price of the credit tokens. This can be done purposefully to create a CREDIT savings rate, but it's not the case that we always want 100% of interest to accumulate in the current CREDIT price. Instead, the surplus buffer can be allocated to productive exogenous assets which can be used to meet liquidity demands or absorb losses.

The mechanism we've discussed for the latter is the "swap" : a variant of the callable loan with a `callFee` and `callPeriod` of zero, which is like a PSM except that while mint is on-demand, redemption occurs by auction. Unlike a regular callable loan, after a swap auction, the remaining surplus is retained by the protocol instead of returned to the borrower (since in this case they are not a borrower, but a seller, and gave up the rights to the asset). Just as GUILD holders vote to allocate debt ceilings of the credit tokens, they can vote to physically their pro rata share of a given asset into a swap of their choice. 

The global debt ceiling of credit tokens available for swaps should be based on the size of the total surplus buffer, and when a swap of a credit token for an exogenous asset occurs, the debt ceiling decremented.

Unifying GUILD redemption with the swap model solves our outstanding accounting issues. If the GUILD holders want to take profits, they can allow for a swap of GUILD for CREDIT or other PCV asset. Likewise, GUILD holders can grow the surplus buffer by defining terms under which GUILD can be swapped for using various assets.

28 March 2023

Introduce new concept of `debtDiscountRate` (TODO: a better name). The goal is to prevent bankruns that occur in the event of bad debt.

Normally when there is bad debt beyond what can be recapitalized in a Compound style market or a PSM based stablecoin like DAI, there is a bankrun on available reserves, and then an internecine situation in which borrowers may be able to repay their loans at a discount depending on users' urgency to exit, while the last lenders will be left with a 100% loss.

The only way to fix this is to be able to mark down bad debt in a timely manner on chain, without letting a subset of users receive warning and exit against protocol funds before the markdown. Any time that calling a loan results in a partial repayment, the `debtDiscountRate` is marked down accordingly, such that to repay all outstanding loans in the protocol, every circulating CREDIT must be repaid. So long as bad debt is not left uncalled while sound loans are called (which any honest minority GUILD holder will not tolerate), this mitigates run risk in the callable loans model.

