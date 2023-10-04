# Ethereum Credit Guild
> version 1

Dominant lending protocols like MakerDAO, Aave, and Compound rely on trusted oracles and have "closed" governance processes where changes to parameters are forced through a central decision-making process. They make honest majority assumptions, lack bad debt markdown mechanisms, and cannot scale to support a truly large diversity of lending terms.

Recent attempts to address these problems involve isolated markets, helping to silo risk but fragmenting liquidity, as well as peer to peer markets, which remove trust assumptions but impose complexity upon users.

The Ethereum Credit Guild seeks to strike a new middle ground between honest-majority systems and pure peer to peer lending. Incentive alignment and appropriate checks and balances allow saving and credit operations without relying on trusted third parties, and responding on demand to changes in the market through an open parameter control process. The system makes an **honest minority assumption**, and if you possess sufficient tokens to constitute that minority, requires no trust assumptions at all. Its failure mode is to safely end lending operations (with borrowers compensated for the inconvenience), and one or several new iterations can be started with their own ownership distributions.

We hope to see a diversity of markets applying the same core principles as this the v1 market described in this document, as well as continued development of the core technology, especially in regards to scaling.

- [Ethereum Credit Guild](#ethereum-credit-guild)
  - [Overview](#overview)
    - [Quorum Actions](#quorum-actions)
    - [Gauge Voting](#gauge-voting)
    - [Borrowing and Liquidation](#borrowing-and-liquidation)
    - [Saving](#saving)
    - [GUILD Minting](#guild-minting)
  - [Mechanism Detail](#mechanism-detail)
    - [Lending Terms](#lending-terms)
    - [GUILD Minting](#guild-minting-1)
    - [Handling Bad Debt](#handling-bad-debt)
  - [Pricing Credit](#pricing-credit)
  - [Bootstrapping Credit](#bootstrapping-credit)
    - [Governance](#governance)

## Overview

There exist two tokens in the system, the stable credit token `CREDIT` the governance token `GUILD`.

The set of actions possible in the system are tightly constrained.

### Quorum Actions

In several cases, a certain quorum of `GUILD` holders can perform a system action or make a parameter change, and another quorum veto it. Each action may have distinct quorums and voting periods or other delays.

  * adjust the global debt ceiling of any credit token
  * approve a new `LendingTerm`, which defines collateral ratios, interest rates, etc
  * remove an existing `LendingTerm`
  * adjust the split of interest between `GUILD` stakers, the `CREDIT` savings rate, and the surplus buffer
  * adjust the voting duration or quorum threshold for any of the above processes

### Gauge Voting

At any time, an individual `GUILD` holder can vote in the gauges for a `LendingTerm`, increasing its credit limit by their pro rata share of the global debt ceiling of the relevant credit token. This puts their `GUILD` tokens at risk of slashing in case of loss. If the slashed tokens are free floating `GUILD`, they are auctioned for `CREDIT`, with the proceeds sent to the surplus buffer. If they are `GUILD` minted against collateral, they are burnt, and a proportional share of the collateral is auctioned, with proceeds likewise sent to the surplus buffer. To unstake, the lending term must be below its debt ceiling, or they must first call one or more loans. This is to ensure no one can exit when they should be slashed, and a staker bears the cost of the call fee on the term they have voted for. Upon unstaking, the debt ceiling is also reduced. Staked `GUILD` holders earn a share of the interest paid under the terms they vote for. This split is determined by governance.

### Borrowing and Liquidation
  
* anyone can mint and borrow credit tokens from a `LendingTerm` with an available credit limit by providing the requisite collateral
* anyone can repay anyone's debt at any time
  * when the loan is repaid, the principal is burnt, part of the interest is paid to those those `GUILD` holders staking on that loan's terms, part to the surplus buffer, and part to the `CREDIT` savings rate
* anyone can call a loan by paying the call fee (in the borrowed token, deducted from the borrower's debt and burnt)
  * this initiates the call period during which the borrower is free to repay at a discount equal to the call fee
* anyone can liquidate a loan after the call period has passed, repaying all or part of the debt and receiving all or part of the collateral depending on auction results
  * in the event of a partial repayment, the loss is deducted from the surplus buffer, with any further loss marked down for all holders of the relevant credit token

### Saving

Anyone can subscribe to the `CREDIT` savings rate, allowing them to earn yield on their `CREDIT` distributed through a rebase mechanism. This means by default, smart contracts like Uniswap pairs which are not compatible with the savings rebase are excluded. `CREDIT` holders do not take on additional risk by subscribing to the savings rate vs holding raw `CREDIT`. A subscriber to the savings rate makes a bet that the loans are sound and interest rates appropriate. It is possible that losses will occur in excess of the surplus buffer, resulting in bad debt and a reduction in the unit price of `CREDIT`. While `CREDIT` holders can be passive with only an honest minority trust assumption in the `GUILD` holder set, they should still form a clear understanding of the risks they are exposed to in the collateral types and loan terms supported by the Ethereum Credit Guild.

### GUILD Minting

Anyone can deposit `CREDIT` to mint `GUILD` tokens. The minted tokens cannot be transfered to other users, and are kept in a wrapper contract that allows limited functionality. They can **only** be used to propose new lending terms and vote in the gauges. This allows outside participation of first loss capital, without making the system vulnerable to griefing by capital entering and vetoing all changes. If the `GUILD` minted against `CREDIT` is slashed while voting in a gauge, that `CREDIT` can be seized and used to repay bad debt.

## Mechanism Detail

### Lending Terms

A [LendingTerm]([.src/loan/LendingTerm.sol](https://github.com/volt-protocol/ethereum-credit-guild/blob/main/src/loan/LendingTerm.sol)) is a blueprint for a loan. It has the following parameters:

* maxDebtPerCollateralToken
  * max number of debt tokens issued per collateral token
* interestRate
  * interest rate paid by the borrower, expressed as an APR
* maxDelayBetweenPartialRepay
  * maximum delay, in seconds, between partial debt repayments
  * if set to 0, no periodic partial repayments are expected
  * if a partial repayment is missed (delay has passed), the loan can be called without paying the call fee
  * exists to support loans requiring periodic payments if desired, probably will be zero on most loans
* minPartialRepayPercent
  * minimum percent of the total debt (principal + interests) to repay during partial debt repayments
  * as above, likely zero in most loans
* callFee
  * exists to prevent griefing of healthy borrower positions
  * paid by the caller when loan is called
  * expressed as percentage of the borrowAmount
  * if borrower fully repays, or loan is revealed to be healthy at liquidation, caller forfeits the fee to borrower
  * if loan is unhealthy at liquidation, or underwater, the caller is reimbursed the call fee
* callPeriod
  * the length of time between the loan being called and the start of the liquidation auction, during which the borrower has the chance to repay
* ltvBuffer
  * the threshold that determines whether a loan is healthy or unhealthy for the purposes of reimbursing the call fee
* hardCap
  * the maximum CREDIT mintable by this lending term, regardless of gauge allocations
* liquidationPenalty

Individual loans have the following structure:

```
    struct Loan {
        address borrower;
        uint256 borrowAmount;
        uint256 collateralAmount;
        address caller; // a caller of 0 indicates that the loan has not been called
        uint256 callTime; // a call time of 0 indicates that the loan has not been called
        uint256 originationTime; // the time the loan was initiated
        uint256 closeTime; // the time the loan was closed (repaid or liquidated)
    }
```

Using a lending term, a borrower can do the following:

```
* borrow(address borrower, uint256 borrowAmount, uint256 collateralAmount) returns (bytes32 loanId) {}
* borrowbySig(address borrower, uint256 borrowAmount, uint256 collateralAmount, uint256 deadline, Signature calldata sig) returns (bytes32 loanId) {}
* borrowWithPermit(uint256 borrowAmount, uint256 collateralAmount, uint256 deadline, Signature calldata sig) returns (bytes32 loanId) {}
* addCollateral(bytes32 loanId, uint256 collateralToAdd) {}
* addCollateralBySig(address borrower, bytes32 loanId, uint256 collateralToAdd, uint256 deadline, Signature calldata sig) {}
* addCollateralWithPermit(bytes32 loanId, uint256 collateralToAdd, uint256 deadline, Signature calldata sig) {}
* addCollateralBySigWithPermit(address borrower, bytes32 loanId, uint256 collateralToAdd, uint256 deadline, Signature calldata addCollateralSig, Signature calldata permitSig) {}
* partialRepay(bytes32 loanId, uint256 debtToRepay) {}
* partialRepayBySig(address repayer, bytes32 loanId, uint256 debtToRepay, uint256 deadline, Signature calldata sig) {}
* partialRepayWithPermit(bytes32 loanId, uint256 debtToRepay, uint256 deadline, Signature calldata sig) {}
* partialRepayBySigWithPermit(address repayer, bytes32 loanId, uint256 debtToRepay, uint256 deadline, Signature calldata repaySig, Signature calldata permitSig) {}
* repay(bytes32 loanId) external {}
* repayBySig(address repayer, bytes32 loanId, uint256 deadline, Signature calldata sig) {}
* repayWithPermit(bytes32 loanId, uint256 maxDebt, uint256 deadline, Signature calldata sig) {}
* repayBySigWithPermit(address repayer, bytes32 loanId, uint256 maxDebt, uint256 deadline, Signature calldata repaySig, Signature calldata permitSig) {}
```

The bySig and bySigWithPermit variants of each function allow maximum convenience, for example, one could set up conditional orders to open or unwind borrowing positions based on custom data feeds.

Besides the borrower, others will be interested in calling the following functions. Note the three possible results of a loan once called.

**Healthy**: above the LTV buffer, the borrower is compensated with the call fee whether they choose to repay or are liquidated by auction

**Unhealthy**: below the LTV buffer, the caller is reimbursed the call fee, and the borrower pays the liquidation penalty

**Underwater**: below the outstanding debt, the caller is reimbursed the call fee, and gauge voters can be slashed

```
/// the borrower has callPeriod to repay before the collateral can be seize()'d and sent to auction
* call(bytes32 loanId) {}
* callMany(bytes32[] memory loanIds) {}
* callManyBySig(address caller, bytes32[] memory loanIds, uint256 deadline, Signature calldata sig) {}
* callManyWithPermit(bytes32[] memory loanIds, uint256 deadline, Signature calldata sig) {}
* callManyBySigWithPermit(address caller, bytes32[] memory loanIds, uint256 deadline, Signature calldata callSig, Signature calldata permitSig) {}
* seize(bytes32 loanId) {}
* seizeMany(bytes32[] memory loanIds) {}

/// an emergency function that can be used in the event collateral is frozen and cannot be sent to the auction house, to mark down bad debt
/// namely, if a centralized stablecoin freezing the lending term address, it would otherwise freee the system
* forgive(bytes32 loanId) {}
/// this allows governance to migrate to a new auction house
/// while it may change the results of a liquidation due to its parameters, the call fee and call period are immutable once a loan is originated
* setAuctionHouse(address _newValue) onlyCoreRole(CoreRoles.GOVERNOR) {}
/// adjust the max debt ceiling (actual debt ceiling is whichever is lower of the gauge vote and the max) up or down
* setHardCap(uint256 _newValue) onlyCoreRole(CoreRoles.TERM_HARDCAP) {}
```

Governable functions like `forgive()` and `setAuctionHouse` will be vetoable by a GUILD holder minority, except in special cases, such as where a periphery contract can detect that a centralized stablecoin blacklisted a lending term, and can then trustlessly call `forgive()`. 

### GUILD Minting

The objective for allowing GUILD minting against collateral is for `GUILD` holders to be able to define how much external first loss capital is desired, and how much yield will be paid to this capital, and to allow external participants in governance without a need to buy GUILD tokens on the market, which restricts the potential participant pool.

Allowing `CREDIT` to be used as the primary collateral to mint `GUILD` makes the system self-governing by its users, which is especially desirable in the early system when we can expect a relatively sophisticated user base. Over time, the `GUILD` holder base will diversify and the `CREDIT` supply will grow to include many more passive users, so there may be less need to input outside first loss capital, especially if a healthy surplus buffer is accumulated.

```
/// usable by a quorum of GUILD holders to allow a certain collateral asset to mint GUILD at a given rate and ratio
* addMintingTerm(address collateralToken, uint256 mintRatio, uint256 interestRate) returns (bytes32 termId) {}
/// usable by a quorum of GUILD to remove a certain minting term for GUILD
* removeMintingTerm(bytes32 termId) {}
/// provide collateral and mint GUILD, vote in a gauge
* openPosition(bytes32 termId, uint256 amountToMint, address gaugeToVote) returns (bytes32 loanId) {}
/// withdraw vote from gauge, repay loan, withdraw collateral
* closePosition(bytes32 loanId) {}
/// change gauge vote
* vote(address gaugeToVote) {}
/// if a user is voting for a gauge that has been slashed, check how much their loss is, seize a proportional amount of their collateral, and auction it for GUILD (the seized GUILD has already been auctioned to repay the bad debt)
/// their debt is also reduced accordingly
* seizeCollateral(bytes32 loanId) {}
```

### Handling Bad Debt

Existing decentralized finance protocols like Aave, Compound, or MakerDAO lack mechanisms to swiftly mark down bad debt and prevent bank runs. Users who withdraw (in the case of Aave or Compound) or redeem via the Peg Stability Module (in the case of MakerDAO) can avoid any loss, while those who are too slow risk a 100% loss.

We mitigate this risk by eliminating atomic, on demand withdrawals, in favor of the mechanic of callable loans. Most loans will have a call period during which the borrower can repay. A loan may have a call period of zero to simulate the function of a PSM or Compound pool, but since liquidation occurs by auction, it will still set a market price instead of allowing some users to redeem above peg after a loss has occurred.

This alone does not solve bank run risk, as when partial repayment is accepted in a liquidation auction, there are more credits in circulation compared to the amount of credit owed as debt, and so the 'leftover' credits are worthless if all the loans are called or repaid.

In the case where the liquidation of collateral does not cover the full `CREDIT` debt, the `CREDIT` token value is marked down proportionately (2% bad debt = 2% target `CREDIT` value decrease), and all remaining debt positions are marked up proportionately, so that the value of healthy debt positions remain constant. This is achieved by allowing more `CREDIT` to be minted from the same collateral in the existing lending terms, which should create arbitrage opportunities to decrease the price of `CREDIT` in secondary markets.

Once bad debt is realized, stakers in the associated gauge can be slashed, and their tokens (or the underlying collateral) auctioned to recover as much value as possible for the lenders. Any recovered value will be claimable by those affected by the bad debt from the surplus buffer. The CREDIT token keeps track of balance timestamps when transfers occur, making it possible to trustlessly verify a user's balance at a point in the past, and for them to claim a distribution of auction proceeds.

This asynchronous process is necessary because if 

-------------

## Pricing Credit

The CREDIT token's "target price" is set implicitly by the lending terms. If the CREDIT supply is backed on average by loans with a 10% overcollateralization and a 0.50% call fee, with the lowest available collateralization at 0.50% using stablecoin collateral, then the price of CREDIT is unlikely to go outside a range of +-0.50% by more than a minimum needed to incentivize arbitrage. CREDIT will have a soft starting target price of $100, to make clear that it is not a $1 stablecoin, but a stable debt unit with trust minimized governance that allows holders to earn interest from borrowers.

The price to obtain liquidity against CREDIT in a given size is calculated by adding up available loans in order from lowest to highest call fee until the desired size is reached. The current market price of CREDIT may trade at a premium when there are net inflows, enough to incentivize minting, or at a small discount based on the available interest rates and cost of calling loans.

We plan to release open source models for monitoring price and liquidity conditions, and also greatly appreciate contributions along these lines.

-------------

## Bootstrapping Credit

CREDIT will be launched under a guarded beta with a low debt ceiling. Participants can engage based on their own interest and at their own risk. The Electric Development Co will provide liquidity for CREDIT on AMMs to make the system usable for early borrowers. Launch liquidity will be at the soft target price of $100 per CREDIT, any further liquidity added will be at the current market price. Provision of liquidity by the Electric Development Co is not guaranteed to last over any duration, and borrowers are responsible for any costs they incur opening or closing positions.

Especially in the early period, supply/demand mismatches in AMM liquidity are to be expected. The protocol supports signed messages, and the open source tooling associated with the ECG will include capacity for swap or borrow requests.

GUILD will be distributed on an ongoing basis to CREDIT holders and minters, encouraging decentralization of the supply and an engaged owner-user base in the early period. GUILD will be nontransferable upon protocol launch, and only usable for voting and gauge staking, discouraging purely speculative yield farming and the growth of an unsustainably large capital base.

### Governance

During the guarded beta, governance will retain emergency powers intended to respond against any unintended system behavior or vulnerability. After the beta period, governance powers will be burnt and no further arbitrary code changes possible. Instead, the system is build around explicitly defined processes such as the onboarding and offboarding of lending terms, or adjusting system parameters such as the surplus buffer fee. 

We recognize that setting loan terms is a more specialized activity than saving, or choosing which yield bearing asset to hold. The protocol attempts to strike a balance through an optimistic governance model, where a relatively small quorum of GUILD is empowered to take system actions but this is also vetoable. This means that outsiders have a reasonably low hurdle to making their voice heard (ie, getting just one or two major delegates to support their proposal) while large stakeholders can ensure malicious proposals do not pass. In the event of sufficient disagreement, the system should bias towards safety and stasis, and disgruntled parties who wish for change can exit. Forking is not just expected, but encouraged.