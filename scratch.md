28 March 2023

Introduce new concept of `debtDiscountRate` (TODO: a better name). The goal is to prevent bankruns that occur in the event of bad debt.

Normally when there is bad debt beyond what can be recapitalized in a Compound style market or a PSM based stablecoin like DAI, there is a bankrun on available reserves, and then an internecine situation in which borrowers may be able to repay their loans at a discount depending on users' urgency to exit, while the last lenders will be left with a 100% loss.

The only way to fix this is to be able to mark down bad debt in a timely manner on chain, without letting a subset of users receive warning and exit against protocol funds before the markdown. Any time that calling a loan results in a partial repayment, the `debtDiscountRate` is marked down accordingly, such that to repay all outstanding loans in the protocol, every circulating CREDIT must be repaid. So long as bad debt is not left uncalled while sound loans are called (which any honest minority GUILD holder will not tolerate), this mitigates run risk in the callable loans model.

