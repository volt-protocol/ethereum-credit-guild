# Ethereum Credit Guild

> ECG version 1

> The Ethereum Credit Guild is the next iteration of what we once knew as Volt Protocol. The goal remains unchanged: to create a credibly neutral and censorship resistant savings and credit system. The mechanism has evolved meaningfully. Most importantly, this model unifies all minting within a CDP/debt issuance model with ephemeral loan terms that do not rely on an external trusted oracle. Automated systems for borrowing or liquidating must exist on top of this neutral base layer. 

Dominant lending protocols like MakerDAO, Aave, and Compound rely on trusted oracles and have "closed" governance processes where changes to parameters are forced through a central decision-making process. They make honest majority assumptions, lack bad debt markdown mechanisms, and cannot scale to support a truly large diversity of lending terms.

Recent attempts to address these problems involve isolated markets, helping to silo risk but fragmenting liquidity, as well as peer to peer markets, which remove trust assumptions but impose complexity upon users.

The Ethereum Credit Guild seeks to strike a new middle ground between honest-majority systems and pure peer to peer lending. Incentive alignment and appropriate checks and balances allow saving and credit operations without relying on trusted third parties, and responding on demand to changes in the market through an open parameter control process. The system makes an **honest minority assumption**, and if you possess sufficient tokens to constitute that minority, requires no trust assumptions at all. Its failure mode is to safely end lending operations (with borrowers compensated for the inconvenience), and one or several new iterations can be started with their own ownership distributions.

We hope to see a diversity of markets applying the same core principles as this the v1 market described in this document, as well as continued development of the core technology, especially in regards to scaling.

- [Ethereum Credit Guild](#ethereum-credit-guild)
  - [Links](#links)
  - [2023-12 code4rena contest](#2023-12-code4rena-contest)
    - [Contest Details](#contest-details)
      - [Ethereum Credit Guild audit details](#ethereum-credit-guild-audit-details)
      - [Automated Findings / Publicly Known Issues](#automated-findings--publicly-known-issues)
    - [Scope](#scope)
    - [Contracts](#contracts)
    - [Additional Context](#additional-context)
      - [Attack Ideas](#attack-ideas)
      - [Main invariants](#main-invariants)
      - [Scoping Details](#scoping-details)
    - [Tests](#tests)
    - [Coverage](#coverage)
  - [High-level Protocol Overview](#high-level-protocol-overview)
    - [Introduction](#introduction)
      - [Quorum Actions](#quorum-actions)
      - [Gauge Voting](#gauge-voting)
      - [Borrowing and Liquidation](#borrowing-and-liquidation)
      - [Saving](#saving)
      - [GUILD Minting](#guild-minting)
    - [Mechanism Detail](#mechanism-detail)
      - [Lending Terms](#lending-terms)
      - [GUILD Minting](#guild-minting-1)
      - [Handling Bad Debt](#handling-bad-debt)
    - [Bootstrapping Credit](#bootstrapping-credit)
      - [Governance](#governance)

## Links

- **Previous audits:** private (2)
- **Documentation:** https://credit-guild.gitbook.io/
- **Website:** n/a
- **Twitter:** https://twitter.com/creditguild
- **Discord:** https://discord.gg/qpk4afhdHp

## 2023-12 code4rena contest

### Contest Details

#### Ethereum Credit Guild audit details
- Total Prize Pool: $90,500 USDC
  - HM awards: $61,875 USDC
  - Analysis awards: $3,750 USDC
  - QA awards: $1,875 USDC
  - Bot Race awards: $5,625 USDC
  - Gas awards: $1,875 USDC
  - Judge awards: $9,000 USDC
  - Lookout awards: $6,000 USDC
  - Scout awards: $500 USD
- Join [C4 Discord](https://discord.gg/code4rena) to register
- Submit findings [using the C4 form](https://code4rena.com/contests/2023-12-ethereumcreditguild/submit)
- [Read our guidelines for more details](https://docs.code4rena.com/roles/wardens)
- Starts December 11, 2023 20:00 UTC
- Ends December 28, 2023 20:00 UTC

#### Automated Findings / Publicly Known Issues

The 4naly3er report can be found [here](https://github.com/code-423n4/2023-12-ethereumcreditguild/blob/main/4naly3er-report.md).

Automated findings output for the audit can be found [here](https://github.com/code-423n4/2023-12-ethereumcreditguild/blob/main/bot-report.md) within 24 hours of audit opening.

_Note for C4 wardens: Anything included in this `Automated Findings / Publicly Known Issues` section is considered a publicly known issue and is ineligible for awards._

Known issues :
- Accounting is "pessimistic", which is at odd with how lending protocols usually work. Interest is distributed to lenders only after it is paid by borrowers.
- Some contracts do not follow CEI. This is because they only do calls to other immutable protocol contracts, and the only "interactions" considered to have to happen after state updates are interactions to untrusted external contracts (like collateral tokens).
- A quorum of `GUILD` or `gUSDC` can block all governance actions except lending term offboarding. This is expected and the protocol would rather bias towards immutability and the ability to safely wind down than require large governance votes for everything. Forks are expected in case of strong cohort disagreements.
- In profit distribution, savings rate can receive rewards even if the split is 0%, because of rounding down.
- Collateral tokens can remain unclaimable by anyone (only by `GOVERNOR` role) and stay on lending terms if loans are forgiven
- Rate limited `gUSDC` minter does not take `creditMultiplier` into account for buffer size & replenish rate
- If there are no rebasing users, distribution of profits on `gUSDC.distribute()` are burnt. The deployer address is expected to mint `100e18` `gUSDC` before anyone interacts with the protocol, which also prevents share price manipulation.

### Scope

All contracts in the `src` folder are in scope, except those in `src/external`. Their inherited & library contracts are also in scope.

The deployment script of the protocol, located in `test/proposals/gips/GIP_0.sol` is also in scope, as protocol deployment/configuration mistakes could be made.

### Contracts

| Contract | SLOC | Sepolia Deployment | Purpose |
| --- | --- | --- | --- |
| `core/Core.sol` | 40 | [CORE](https://sepolia.etherscan.io/address/0x5864658b6b6316e5e0643ad77e449960ee128b04#code) | Core is referenced by all contracts and manages access control |
| `core/CoreRef.sol` | 59 | n/a | Core reference abstract contract inherited by all contracts |
| `core/CoreRoles.sol` | 28 | n/a | List of Core roles |
| `governance/GuildGovernor.sol` | 127 | [DAO_GOVERNOR_GUILD](https://sepolia.etherscan.io/address/0x6ec182c9630ce9b254621cdfa3bdde7cb90a9b67#code) | Governor for DAO votes (based on OZ) |
| `governance/GuildTimelockController.sol`| 27 | [DAO_TIMELOCK](https://sepolia.etherscan.io/address/0x3bddf2b83245f8806d31f9e753c578c254531cc1#code), [ONBOARD_TIMELOCK](https://sepolia.etherscan.io/address/0x8f360bd4db5a37296a63a83e9517d77d94b0907e#code) | Timelock for DAO votes (based on OZ) |
| `governance/LendingTermOffboarding.sol` | 130 | [OFFBOARD_GOVERNOR_GUILD](https://sepolia.etherscan.io/address/0xda70ad8ae77a98cc0064df63a8421acc128432ac#code) | Mini-governor that manages offboarding of lending terms, with fast execution |
| `governance/LendingTermOnboarding.sol`  | 196 | [ONBOARD_GOVERNOR_GUILD](https://sepolia.etherscan.io/address/0x27f428bb83f33ea33a22ed3cd015f61362f641da#code) | Special-purpose governor that managed onboarding of lending terms, also acts as a lending term factory |
| `governance/ProfitManager.sol` | 325 | [PROFIT_MANAGER](https://sepolia.etherscan.io/address/0xd8c5748984d27af2b1fc8235848b16c326e1f6de#code) | Central accounting place of the protocol where all lending terms report profit & losses. Handles distribution of profits |
| `governance/GuildVetoGovernor.sol` | 231 | [DAO_VETO_GUILD](https://sepolia.etherscan.io/address/0x56ca5ffbe81672d9b2f1a406b4cb3c7d636e24d0#code), [DAO_VETO_CREDIT](https://sepolia.etherscan.io/address/0xde1c8b9bdf44ded73456e1b976251423a0534bb6#code), [ONBOARD_VETO_GUILD](https://sepolia.etherscan.io/address/0x68213c815ec33e127023da0ed0a7009d017a3ec3#code), [ONBOARD_VETO_CREDIT](https://sepolia.etherscan.io/address/0x93049dbd623b4a1d8dcea928751cce4b1eeb2d3a#code) | Veto Governor where DAO votes to cancel an action queued in a timelock can be created |
| `tokens/ERC20Gauges.sol` | 294 | n/a | Gauge staking system inherited by `GUILD` token used to determine the relative debt ceilings of lending terms |
| `tokens/ERC20MultiVotes.sol` | 302 | n/a | ERC20 vote token that allows delegation to multiple addresses. Inherited by both `GUILD` and credit tokens |
| `tokens/ERC20RebaseDistributor.sol` | 499 | n/a | Rebasing ERC20 abstract class inherited by credit tokens, used to distribute value to lenders |
| `tokens/CreditToken.sol` | 108 | [ERC20_GUSDC](https://sepolia.etherscan.io/address/0x33b79f707c137ad8b70fa27d63847254cf4cf80f#code) | ERC20 token representing credit (debt) in the system. Holders of credit tokens are lenders to the protocol |
| `tokens/GuildToken.sol` | 196 | [ERC20_GUILD](https://sepolia.etherscan.io/address/0xcc65d0feaa7568b70453c26648e8a7bbef7248b4#code) | Governance token of the ECG. Non-transferrable at launch |
| `loan/AuctionHouse.sol` | 141 | [AUCTION_HOUSE](https://sepolia.etherscan.io/address/0x723fc745cc58122f6c297a12324fa3245ce920b7#code) | Dutch auction system used in liquidations |
| `loan/LendingTerm.sol` | 563 | [LENDING_TERM_V1](https://sepolia.etherscan.io/address/0x253df16fe3e2070ec5d1a6dd50c1a3fe3c349c7f#code), [TERM_SDAI_1](https://sepolia.etherscan.io/address/0xfbe67752bc63686707966b8ace817094d26f5381#code), [TERM_WBTC_1](https://sepolia.etherscan.io/address/0x3c34b8d9c4680e6870f1c5311f4631217a505974#code) | Manages lending (borrow, repay...). One implementation, several proxy clones listed as gauges |
| `loan/SimplePSM.sol` | 99 | [PSM_USDC](https://sepolia.etherscan.io/address/0x66839a9a16beba26af1c717e9c1d604dff9d91f7#code) | Used to maintain peg between credit tokens and a reference asset |
| `loan/SurplusGuildMinter.sol` | 222  | [SURPLUS_GUILD_MINTER](https://sepolia.etherscan.io/address/0x3b5b95249b0a598a4347be4c2736ad4eb877b16d#code) | Used to provide first-loss capital in credit tokens to borrow `GUILD` and participate in the gauge system without exposure to `GUILD` token price |
| `rate-limits/RateLimitedMinter.sol` | 36 | [RATE_LIMITED_GUILD_MINTER](https://sepolia.etherscan.io/address/0xa29b96371dec4edaac637ee721c16046ee0b7dff#code), [RATE_LIMITED_CREDIT_MINTER](https://sepolia.etherscan.io/address/0xc8197e8b9ffe1039761f56c41c6ce9cbc7c2d1d9#code) | Implements limitations on `GUILD` and credit tokens minting |
| `utils/RateLimitedV2.sol` | 98 | n/a | Abstract class util for rate limits |

Total SLOC: 3739

### Additional Context

- **Isolated markets:** by default, each lending asset is risk isolated and has its own set of available lending terms, so bad debt in the ETH market will not affect USDC lenders. It's possible to link the markets by accepting each others' deposit receipts as collateral (gUSDC, gETH, etc).
- **Auction mechanism:** at first, offer 0% collateral, ask 100% debt. Then, over time, offer a larger % of the collateral and still 100% debt. At 'midpoint', 100% collateral is offered asking for 100% debt, and if nobody has bid, bad debt will be realized. In the second phase, 100% collateral is offered and less and less debt is asked. When we reach the end of the auction (100% collateral offered, 0% debt asked), nobody can bid in the auction anymore, and the loans can be automatically forgiven (marking it as a 100% loss). The first to bid wins the auction, making it a race to arbitrage (onchain MEV or otherwise).
- **Collateral tokens**: The protocol is expected to handle properly most widely used ERC20 tokens as collateral. The collateral tokens are the least trusted external calls in the system. At launch, we expect to interact with RWA tokens, LSD tokens, and yield-bearing tokens in general, but **no rebasing tokens** and **no fee on transfer**.
- **Deployment**: we anticipate to launch on Ethereum mainnet & L2s like Arbitrum.
- **Trusted actors**: The addresses with `GOVERNOR` and `GUARDIAN` role are trusted. DAO timelock can execute arbitrary calls and impersonate all protocol contracts, as it holds the `GOVERNOR` role. The team multisig has the `GUARDIAN` role, and it is expected to be able to freeze new usage of the protocol, but not prevent users from withdrawing their funds.
- **Trust minimization**: we expect most roles to be "burnt" (especially `GOVERNOR` and `GUARDIAN`), by deploying automated governance processes that use these privilege but can only make pre-determined calls. Lending term onboarding & offboarding could be done with a simple timelock, but we wrote helper contracts to automate these governance processes, and most governance processes like parameter tuning will be secured like this in the future.
- **DOS**: In the event of a chain DOS, we expect the system to behave properly (as in, if collateral token values change, or auctions in progress end, we expect the bad debt to be properly marked down when the chain becomes functional again).
- **Collateral of forgiven loans**: there could be manual airdrops organized by the DAO if loans have to be forgiven because collateral tokens are temporarily reverting on transfer.

#### Attack Ideas

- Malicious collateral: onboard a lending term with an ERC20 collateral token that is an upgradeable proxy, then upgrade the proxy in a creative way to brick the ECG internal logic & prevent proper bad debt realization
- Share price / interpolation manipulation in `ERC20RebaseDistributor` leading to incorrect balances of credit tokens
- Messing up with the accounting logic by opening multiple loans and/or repaying in part some debts, or exploiting side effectfs of updates to the `creditMultiplier` (bad debt realization), or donating tokens, etc, that could lead to an invalid profit sharing among protocol participants or reverts during the process of profit distribution
- Gaming around the auction mechanism by bidding above market price on our own loans during liquidation (recovering the full collateral and essentially having the same effect as a `repay()`), then re-opening a loan in a risky term

#### Main invariants

- **Debt value**: The debt value should be constant in `USDC` term (+interest over time), even if the `gUSDC` token loses value due to bad debt creation.
- **Profit distribution**: Interest paid by borrowers should be entirely redistributed between lenders (`gUSDC` holders, current or future due to interpolation of rewards), `GUILD` stakers (+ `GUILD` borrowers that stake through the `SurplusGuildMinter`), and the surplus buffers.
- **Issuance**: Issuance of lending terms should be 0 if there are no loans open, so that the terms can be offboarded properly.
- **Issuances**: The sum of all terms issuance should be less than the total debt owed by borrowers (due to interests accruing + eventual loss of values of the `gUSDC` token that marks up all open debts)

#### Scoping Details

```
- If you have a public code repo, please share it here: https://github.com/volt-protocol/ethereum-credit-guild
- How many contracts are in scope?: 21   
- Total SLoC for these contracts?: 3739  
- How many external imports are there?: 20  
- How many separate interfaces and struct definitions are there for the contracts within scope?: 10  
- Does most of your code generally use composition or inheritance?: Inheritance   
- How many external calls?: 2   
- What is the overall line coverage percentage provided by your tests?: 99%
- Is this an upgrade of an existing system?: False
- Check all that apply (e.g. timelock, NFT, AMM, ERC20, rollups, etc.): Timelock function, ERC-20 Token
- Is there a need to understand a separate part of the codebase / get context in order to audit this part of the protocol?: False   
- Please describe required context: see README.md
- Does it use an oracle?: No
- Describe any novel or unique curve logic or mathematical models your code uses: No complex math, but there is a gauge system and a dutch auction mechanism for liquidations 
- Is this either a fork of or an alternate implementation of another project?: False  
- Does it use a side-chain?: No
- Describe any specific areas you would like addressed: LendingTerm, ERC20RebaseDistributor, ERC20Gauges, ProfitManager
```

### Tests

After cloning, run `npm install` to download dependencies (`@openzeppelin/contracts@4.9.3`).

There are 3 kind of Forge tests in the repo :
- Unit tests `npm run test:unit` testing the individual behavior of all contracts
- Integration tests `npm run test:integration` testing the interactions between deployed protocol contracts after running the pending DAO proposals
- Proposal tests `npm run test:proposals` testing the pending DAO proposals

### Coverage

Coverage is generated using Forge.

Running `npm run coverage:unit` gives the coverage of unit tests -> 1161 / 1165 = 99.65% lines covered. But of course that doesn't mean the protocol is bug-free, please attempt to break it ethically.

Running `npm run coverage:integration` gives the coverage of integration tests, it is longer to run.

## High-level Protocol Overview

### Introduction

There exist two kind of tokens in the system, the governance token `GUILD`, and credit tokens pegged to a reference asset.

The first deployment of the protocol only has one credit token pegged to `USDC`: `gUSDC` ("Guild USDC"). In the future, it is expected that multiple markets will be deployed, each with their own credit token, but the `GUILD` token is the same for all markets.

The set of actions possible in the system are tightly constrained.

#### Quorum Actions

In several cases, a certain quorum of `GUILD` holders can perform a system action or make a parameter change, and another quorum veto it. Each action may have distinct quorums and voting periods or other delays. All of these actions are currently subject to veto except for lending term offboarding.

  * adjust the global debt ceiling of any credit token
  * approve a new `LendingTerm`, which defines collateral ratios, interest rates, etc
  * remove an existing `LendingTerm`
  * adjust the split of interest between `GUILD` stakers, the `gUSDC` savings rate, and the surplus buffer
  * adjust the voting duration or quorum threshold for any of the above processes

#### Gauge Voting

At any time, an individual `GUILD` holder can vote in the gauges for a `LendingTerm`, increasing its credit limit by their pro rata share of the global debt ceiling of the relevant credit token. This puts their `GUILD` tokens at risk of slashing in case of bad debt resulting from the lending term they vote for. To unstake, the lending term issuance (borrow amount) must be below its debt ceiling, or they must first call one or more loans. This is to ensure no one can exit when they should be slashed. Upon unstaking, the debt ceiling is also reduced. Staked `GUILD` holders earn a share of the interest paid under the terms they vote for. This split is determined by governance.

#### Borrowing and Liquidation
  
* anyone can mint and borrow credit tokens from a `LendingTerm` with an available credit limit by providing the requisite collateral
* anyone can repay anyone's debt at any time
  * when the loan is repaid, the principal is burnt, part of the interest is paid to those those `GUILD` holders staking on that loan's terms, part to the surplus buffer, and part to the `gUSDC` savings rate
* if a loan missed a period repayment, anyone can call it (resulting in the liquidation of collateral to pay the debt)
  * the borrower can bid on their own collateral in the auction to repay their loan, before someone else takes the arbitrage (leaking part of the loan collateral to bidder instead of borrower)
* loans on a deprecated lending term (that is not an active gauge) can be called
* in the event of a collateral auction covering only part of the debt principal, the loss is deducted from the surplus buffer, with any further loss marked down for all holders of the relevant credit token

#### Saving

Anyone can subscribe to the `gUSDC` savings rate, allowing them to earn yield on their `gUSDC` distributed through a rebase mechanism. This means by default, smart contracts like Uniswap pairs which are not compatible with the savings rebase are excluded. `gUSDC` holders do not take on additional risk by subscribing to the savings rate vs holding raw `gUSDC`. A subscriber to the savings rate makes a bet that the loans are sound and interest rates appropriate. It is possible that losses will occur in excess of the surplus buffer, resulting in bad debt and a reduction in the unit price of `gUSDC` (in `USDC` terms). While `gUSDC` holders can be passive with only an honest minority trust assumption in the `GUILD` holder set, they should still form a clear understanding of the risks they are exposed to in the collateral types and loan terms supported by the Ethereum Credit Guild.

#### GUILD Minting

Anyone can stake `gUSDC` to mint `GUILD` tokens. The minted tokens cannot be transfered to other users, and are kept in a wrapper contract that allows limited functionality. They can **only** be used to vote in the gauges. This allows outside participation of first loss capital, without making the system vulnerable to griefing by capital entering and vetoing all changes. If the `GUILD` minted against `gUSDC` is slashed while voting in a gauge, that `gUSDC` is seized and donated to the surplus buffer before computing losses.

### Mechanism Detail

#### Lending Terms

A `LendingTerm` is a blueprint for a loan. It has the following parameters:

* `maxDebtPerCollateralToken`
  * max number of debt tokens issued per collateral token
* `interestRate`
  * interest rate paid by the borrower, expressed as an APR
* `maxDelayBetweenPartialRepay`
  * maximum delay, in seconds, between partial debt repayments
  * if set to 0, no periodic partial repayments are expected
  * if a partial repayment is missed (delay has passed), the loan can be called
  * exists to support loans requiring periodic payments if desired
* `minPartialRepayPercent`
  * minimum percent of the total debt (principal + interests) to repay during partial debt repayments
* `openingFee`
  * interest instantly accruing after opening the loan
  * expressed as a percent of the borrow amount
* `hardCap`
  * the maximum CREDIT mintable by this lending term, regardless of gauge allocations
  * used to express constraints on the available on-chain liquidity (a term is likely to liquidate all its open loans at once, when the term is offboarded)

Individual loans have the following structure:

```
struct Loan {
    address borrower; // address of a loan's borrower
    uint256 borrowTime; // the time the loan was initiated
    uint256 borrowAmount; // initial CREDIT debt of a loan
    uint256 borrowCreditMultiplier; // creditMultiplier when loan was opened
    uint256 collateralAmount; // balance of collateral token provided by the borrower
    address caller; // a caller of 0 indicates that the loan has not been called
    uint256 callTime; // a call time of 0 indicates that the loan has not been called
    uint256 callDebt; // the CREDIT debt when the loan was called
    uint256 closeTime; // the time the loan was closed (repaid or call+bid or forgive)
}
```

Using a lending term, a borrower can do the following:

* borrow
* addCollateral
* partialRepay
* repay

Besides the borrower, others will be interested in calling the following functions:

* call
* callMany
* seize

Governable functions like `forgive()` and `setHardCap()` will be vetoable by a `GUILD` and `gUSDC` holder minority, except in special cases, such as where a (future) periphery contract could detect that a centralized stablecoin blacklisted a lending term, and can then trustlessly call `forgive()`.

#### GUILD Minting

The objective for allowing GUILD minting against collateral is for `GUILD` holders to be able to define how much external first loss capital is desired, and how much yield will be paid to this capital, and to allow external participants in governance without a need to buy GUILD tokens on the market, which restricts the potential participant pool.

Allowing `gUSDC` to be used as the primary collateral to mint `GUILD` makes the system self-governing by its users, which is especially desirable in the early system when we can expect a relatively sophisticated user base. Over time, the `GUILD` holder base will diversify and the `gUSDC` supply will grow to include many more passive users, so there may be less need to input outside first loss capital, especially if a healthy surplus buffer is accumulated.

#### Handling Bad Debt

Existing decentralized finance protocols like Aave, Compound, or MakerDAO lack mechanisms to swiftly mark down bad debt and prevent bank runs. Users who withdraw (in the case of Aave or Compound) or redeem via the Peg Stability Module (in the case of MakerDAO) can avoid any loss, while those who are too slow risk a 100% loss. Newer protocols like Morpho Blue and the Ethereum Credit Guild attempt to handle bad debt more fairly.

We mitigate this risk by eliminating atomic, on demand withdrawals, in favor of the mechanic of callable loans. Since liquidation occurs by auction, it will still set a market price instead of allowing some users to redeem above peg after a loss has occurred. During a LendingTerm offboarding (while auctions of the collateral of a term are running), redemptions in the PSM are paused.

This alone does not solve bank run risk, as when partial repayment is accepted in a liquidation auction, there are more credits in circulation compared to the amount of credit owed as debt, and so the 'leftover' credits are worthless if all the loans are called or repaid.

In the case where the liquidation of collateral does not cover the full `gUSDC` debt, the `gUSDC` token value is marked down proportionately (2% bad debt = 2% target `gUSDC` value decrease), and all remaining debt positions are marked up proportionately, so that the `USDC` value of healthy debt positions remain constant. This is achieved by allowing more `gUSDC` to be minted from the same collateral in the existing lending terms and in the PSM, which should create arbitrage opportunities to decrease the price of `gUSDC` in secondary markets if any.

Once bad debt is realized, stakers in the associated gauge can be slashed and lose the part of their `GUILD` that was voting for this gauge. First-loss capital provided by staking `gUSDC` to borrow `GUILD` and vote in the gauge is also slashed.

### Bootstrapping Credit

The first market for USDC will be launched under a guarded beta with a low debt ceiling. This means users can mint or redeem in the PSM freely, but borrowing is limited while the collateral pricing and liquidation system is first put in production. Participants can engage based on their own interest and at their own risk.

`GUILD` will be distributed on an ongoing basis to `gUSDC` holders and borrowers, as well as to those who actively participate in staking, encouraging decentralization of the supply and an engaged owner-user base in the early period. `GUILD` will be nontransferable upon protocol launch, and only usable for voting and gauge staking, discouraging purely speculative yield farming and the growth of an unsustainably large capital base.

#### Governance

During the guarded beta, governance will retain emergency powers intended to respond against any unintended system behavior or vulnerability. After the beta period, governance powers will be burnt and no further arbitrary code changes possible. Instead, the system is build around explicitly defined processes such as the onboarding and offboarding of lending terms, or adjusting system parameters such as the surplus buffer fee. 

We recognize that setting loan terms is a more specialized activity than saving, or choosing which yield bearing asset to hold. The protocol attempts to strike a balance through an optimistic governance model, where a relatively small quorum of `GUILD` is empowered to take system actions, but this is also vetoable. This means that outsiders have a reasonably low hurdle to making their voice heard (ie, getting just one or two major delegates to support their proposal) while large stakeholders can ensure malicious proposals do not pass. In the event of sufficient disagreement, the system should bias towards safety and stasis, and disgruntled parties who wish for change can exit. Forking is not just expected, but encouraged.