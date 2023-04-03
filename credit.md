# Ethereum Credit Guild

Existing lending protocols like MakerDAO, Aave, and Compound rely on trusted oracles, and have "closed" governance processes where changes to parameters are forced through a central decision-making process and thus occur at a very limited rate.

The Ethereum Credit Guild seeks to change that, building an incentive aligned system with checks and balances allowing saving and credit operations without relying on trusted third parties, and responding on demand to changes in the market through an open parameter control process.

The **credit** is a decentralized debt based stablecoin, which can follow an arbitrary monetary policy, but we will assume attempts to maintain stability or strength relative to major currencies, particularly the dollar, while appreciating via a floating interest income. Due to fluctuations in the value of the underlying loan book based on market rate volatility, precise price stability in regards to a reference asset cannot be guaranteed.

- [Ethereum Credit Guild](#ethereum-credit-guild)
  - [Mechanisms](#mechanisms)
    - [Lending Terms](#lending-terms)
    - [Exogenous vs Endogenous Asset Borrowing and CREDIT Accounting](#exogenous-vs-endogenous-asset-borrowing-and-credit-accounting)
    - [Borrowing and Repayment](#borrowing-and-repayment)
    - [Calling and Liquidating Loans](#calling-and-liquidating-loans)
    - [Handling Bad Debt](#handling-bad-debt)
    - [Surplus Buffer and Redemptions](#surplus-buffer-and-redemptions)
  - [Pricing Credit](#pricing-credit)
  - [Bootstrapping Credit](#bootstrapping-credit)
    - [On Competitive Advantages in Lending](#on-competitive-advantages-in-lending)
    - [Credit Genesis](#credit-genesis)

## Mechanisms

There exist two kinds of tokens in the system, the stable debt token CREDIT, and the governance and risk backstop token GUILD. So far, so familiar.

### Lending Terms

A GUILD holder with above a minimum threshold of the token supply can propose a new set of lending terms. A `CreditLendingTerm` is a blueprint for a loan. Anyone can define a new lending term, but only those terms whitelisted via the governor and voted for by GUILD holders can be used to mint CREDIT.

A loan term stores information such as:

```
    // the address of the core contract which stores all system addresses
    address public core;
    // the collateral token used for this lending term
    address public collateralToken;
    // the number of credits borrowable per collateral token
    // a token whose unit value is too small will need to be handled differently, TODO
    uint256 public collateralRatio;
    // expressed as a divisor of the loan
    // an interestRate of 20 is equivalent to 5% interest (total debt / 20 per year paid in interest)
    uint256 public interestRate;
    // expressed as a divisor of the loan
    uint256 public callFee;
    // how many seconds must pass between when the loan is called and the first bid can be made in the auction
    uint256 public callPeriod;
    // the unused debt ceiling of this lending term
    uint256 public availableCredit;
    // whether bad debt has accured resulting in slashing for voters
    bool public isSlashable;
    // if the collateral asset is eligible for borrowing, the terms under which this is allowed
    // the zero address means it cannot be borrowed
    address public collateralBorrowTerms;
```

GUILD holders can propose to whitelist a new term, and there is a period during which this can be vetoed.

If not denied during the dispute window, any GUILD holder can vote for that loan term to increase its debt ceiling (whoever proposed it is voting for it by default, so the starting debt ceiling will be at the proposal threshold until users allocate away).

The global debt ceiling is determined determined implicitly based on the `voteWeight` and `totalSupply` in the Guild token contract. The debt ceiling of a particular loan is determined based on the amount of GUILD staked to it. For example, if the `voteWeight` is 1, and there are 10m GUILD tokens, a holder of 10% of the GUILD supply can allocate a debt ceiling of 1m CREDIT to lend against a collateral of their choice.

### Exogenous vs Endogenous Asset Borrowing and CREDIT Accounting

Credits are a synthetic asset whose supply is bounded by the votes of GUILD holders defining lending terms, the willngness of borrowers to mint CREDIT, and of others to hold. On the other hand, deposited collateral assets like ETH have a fixed total in-protocol liquidity distributed across the `LendingTerm`s where collateral is deposited. The protocol will not collect reserve fees or charge interest in any denomination other than CREDIT.

If a user wants to borrow a non-CREDIT asset, they can use CREDIT collateral, and the interest rate is assessed in CREDIT at the time of loan repayment or liquidation. To borrow a non-CREDIT asset using CREDIT collateral, such as borrowing ETH using USDC as collateral, there is a double hop from borrow CREDIT with USDC, then borrow ETH against CREDIT. Using CREDIT as a common unit of account reduces the number of loan terms that must be defined and managed by GUILD holders.

-------------

### Borrowing and Repayment

To initiate a loan, a user must find an acceptable set of lending terms and post collateral. The collateral tokens are held in the associated `CreditLendingTerm` contract while the loan is active, unless they are eligible for borrowing, in which case they may be lent out.

A given lending term mints a fixed number of credits per collateral token, until the available credit is used up. When a user repays their loan, they must repay a greater amount of CREDIT than they borrowed due to the accrued interest. All the credits repaid are burnt. Anyone can repay a loan, though only the user can withdraw their collateral. Partial repayments are not allowed except during the liquidation auction.

--------------

### Calling and Liquidating Loans

Anyone can call a loan issued by the protocol by paying the call fee in either credits or GUILD. The call fee is deducted from the borrower's debt and burnt. There is a period during which the borrower can repay but no one can bid for their collateral known as the `callPeriod`. After this, if the borrower has not repaid, anyone can trigger liquidation by sending the borrower's collateral to the `auctionHouse`. A liquidation auction occurs to repay as much as possible of the borrower's debt by selling off as little as possible of the collateral position. If the auction reveals the loan to be insolvent, the one who triggered the auction is rewarded by being reimbursed the call fee if one was paid plus a liquidation reward. If the loan was insolvent, any GUILD holders voting for that loan's terms have their balances slashed, and the CREDIT that was lost is deducted from the surplus buffer.

The liquidation auction is a Dutch auction where a gradually larger portion of the borrower's collateral is offered in exchange for repaying their debt. If the borrower's entire collateral is not enough to pay their debt, a partial payment is accepted.

The current MVP auction house has a fixed duration for auctions, but this might also be a parameter in the `CreditLendingTerm`.

-------------

### Handling Bad Debt

Existing decentralized finance protocols like Aave, Compound, or MakerDAO lack mechanisms to swiftly mark down bad debt and prevent bank runs. Users who withdraw (in the case of Aave or Compound) or redeem via the Peg Stability Module (in the case of MakerDAO) can avoid any loss, while those who are too slow risk a 100% loss.

We mitigate this risk by eliminating atomic, on demand withdrawals, in favor of the mechanic of callable loans. Most loans will have a call period during which the borrower can repay. A loan may have a call period of zero to simulate the function of a PSM or Compound pool, but since liquidation occurs by auction, it will still set a market price instead of allowing some users to redeem above peg after a loss has occurred.

This alone does not solve bank run risk, as when partial repayment is accepted in a liquidation auction, there are more credits in circulation compared to the amount of credit owed as debt, and so the 'leftover' credits are worthless if all the loans are called or repaid. This is addressed by separately tracking the circulating credit supply, and the total credits issued as debt. When the ratio is not 1:1, the amount of credits minted against collateral or required to repay debts is adjusted accordingly, such that if the entire protocol is unwound, every credit must be used to repay the outstanding loans, and more credits can be issued against the same collateral proportional to the bad debt.

-------------

### Surplus Buffer and Redemptions

GUILD holders can take profits by burning GUILD for a share of the surplus buffer. This mechanism is rate limited such that it cannot destabilize the CREDIT price. The objective of this mechanism is to facilitate a market based rate for CREDIT, which is discussed below, and allow the market to determine the optimal size for the surplus buffer. A GUILD price higher than the intrinsic value implies the system is growing and should increase its first loss capital supply, and the intrinsic value provides a gradually increasing floor price for GUILD barring losses from bad loans.

-------------

## Pricing Credit

The behavior of the CREDIT token will depend on the nature of the loan set that backs it, user interest in CREDIT, and the overall market conditions. There is no foolproof way for software to detect the quality of a collateral token or know what the market interest rate is. These inputs must be provided by humans. The goal of the Ethereum Credit Guild is to allow for market based processes with checks and balances to allow users to enagage in fair and productive lending operations without the need for trusted third parties. If the system is otherwise in equilibrium (no change in demand to hold or borrow credits, or to hold GUILD) then the value of credits will tend to increase over time as the surplus buffer accumulates credits. Based on the internal rate of return, the current value of a credit will fluctuate on the market.

The architecture of CREDIT can support arbitrary liquidity and yield properties. We can envision other versions with lower liquidity and higher yield. We expect the primary CREDIT token to have the same goals as VOLT:
* high liquidity, such that a large portion of the supply can be redeemed in the span of a week
* yield bearing equal to or better than off chain money markets

The recent USDC peg stability has made it clear that there is no such thing as a perfectly fungible, instantly portable dollar. All stablecoins, bank deposits, Paypal balances, etc have some constraints in their fungibility and transferability under certain conditions.

A traditional Peg Stability Module is possible in the architecture of CREDIT we've laid out here -- you just need a `LendingTerm` allowing minting of CREDIT 1:1 with USDC at 0% interest, a call fee of 0, and a call period of 0. This is not the desired implementation, however, instead we prefer a potentially liquidatable vault that allows for an upward drift in credit price representing the accured yield: "mint 1 credit per 1.02 USDC at 4% interest". Arbitrage does not need to be risk free, in fact, it cannot be -- if the arbitrageur is not bearing this risk, the protocol and thus the stablecoin holders are. Maintaining a small interest rate and overcollateralization on arbitrage vaults will mean sacrificing a little bit of the upward peg stability the PSM offers, in exchange for ensuring an incentive exist for new loans to be opened against productive collateral.

The current price of CREDIT is determined by the market; if bad debt occurs, system is more resilient to runs than a PSM model.While it's true that if all active borrowing positions were closed, the remaining CREDIT outstanding would be worthless, this has much less run risk than a PSM allowing on demand redemptions. gand instead though some may sell in a panic, allowing borrowers to repay at or above an appropriate discount based on the amount of bad debt in the system. So long as borrowing demand continues to exist, CREDIT can stabilize at a new price that accounts for the bad debt without distributing it unfairly to certain users. 

-------------

## Bootstrapping Credit

At first, CREDIT will have no liquidity, so it will be difficult for borrowers to use. The members of the Ethereum Credit Guild, such as the core contributors at the Electric Development Co and La Tribu, as well as early investors and advisors who hold the GUILD token, will engage in bootstrapping demand for CREDIT according to their ability and interests. The Electric Development Co will provide liquidity for CREDIT on AMMs to help bootstrap its utility and provide a smooth experience for early borrowers. This will likely take the form of USDC/CREDIT liquidity to provide the lowest cost experience for borrowers obtaining leverage using the Ethereum Credit Guild.

GUILD will be distributed on an ongoing basis to CREDIT holders and minters, encouraging decentralization of the supply and an engaged owner-user base in the early period. GUILD will be nontransferable upon protocol launch, discouraging purely speculative yield farming and the growth of an unsustainably large capital base.

### On Competitive Advantages in Lending

One of the goals of the Ethereum Credit Guild's lending model is to permit more aggressive leverage than pooled lending models generally support against top quality assets. Of all the on chain lending markets, Liquity offers (subject to certain conditions) the highest LTV against ETH at 90.91%, or a maximum acheivable leverage of 11x. Flux Finance, the lending market created by Ondo to support its tokenized securities like OUSG, offers only a 92% collateral factor for OUSG, a short term US treasury ETF, and rates in the market for stablecoins have at times exceeded the underlying treasury yield. Compared to Binance's 20x leverage on ETH, or the 98% collateral factor obtainable on Treasury securities in traditional repo markets[^1], it's tricky to see these venues competing for the business of professional market makers and traders in "offchain" securities. For many traders, whether directional or arbitrage, the amount of leverage available is more important than the interest rate, since the duration of the trade is short.

A lower latency process for governance can enable more efficient lending operations. Onchain operations are constrained by the blocktime, but can do a lot better than traditional governance delays in tuning collateral ratios and interest rates. For low volatility assets like OUSG, the main issue is managing liquidity (as even the best collateral has a varying shiftability), not the risk of a drop in the value of the collateral. In this case, borrowers can be allowed very high leverage, but interest rates should also be very high, so that both CREDIT holders and borrowers can earn an efficient return. For high volatility assets like ETH, one can clearly envision a daily adjustment in available lending terms outperform a static collateral requirement and trusted oracle feed.

### Credit Genesis

Let's walk through what the very beginning of the protocol will look like.

The initial set of GUILD holders will include the Electric Development Company, other core contributors, investors, advisors, and those who earned GUILD/VCON through the Volt Protocol v1 airdrop. These users must reach consensus on an initial set of loan terms (or make however many forks of the code they like!). The larger the size of the protocol, the more often it makes sense to rebalance loan terms from a gas perspective. Therefore, the starting loan terms are expected to be more conservative and (and in need of less frequent updates) than those at scale. **The initial set of loan terms must be able to offer a better deal to some borrower than they can get elsewhere**. At the same time, the early loan set could facilitate efficient liquidity provision.

For example, this set of loan terms might look like:

| Collateral Token      | CREDIT mintable per token |  Interest Rate (% Annual)  |   Call Fee (bips)  |
| ----------- | ----------- | ----------- | -----------|
| ETH      | 1400       | 4  |  15 |
| rETH | 800 | 3.5 | 25 | 
| cbETH | 800 | 3.5 | 25 |
| OUSG  | 97  | 4 | 10 |
| stDAI | 99 | 1 | 5 |
| USDC | 98 | 0 | 5 |
| Univ2CREDITUSDC | .9 | 0 | 1 |
| Univ2CREDITDAI | .9 | 0 | 1 |

Market makers in the early system can take a highly leveraged exposure to CREDIT/USDC or CREDIT/DAI Uniswap v2 LP or other AMM pairing without paying an interest cost. It's possible an incentivized pair could generate profits for the system. While not necessarily highly efficient, providing AMM liquitity is a convenient and familiar way for those bootstrapping the system to provide liquidity and its early users to access it.

In a mature system, it's unlikely GUILD holders will want to vote for zero-interest lending terms, when they could instead vote for a profitable loan. Early on they are likely to do so because they themselves are likely to be bootstrapping CREDIT liquidity.

A few users begin to buy CREDIT on the AMM to start earning GUILD rewards (at first, with no loans issued, it's expected price increase or native yield is zero), pushing its price slightly up. This convinces the first 'real' borrower that it is a good time to take action. They deposit OUSG, which is yielding 4.5%, and borrow CREDIT at 4%, while selling enough CREDIT to bring its price back down to the starting level.

Over time, as borrowers pay interest, the CREDIT price starts to drift up. The available lending terms are adjusted, and the bootstrappers close their AMM positions and repay their loans. Growing demand for CREDIT at this point is met mainly through borrowing against productive collateral like OUSG or stETH. When demand to repay loans or hold CREDIT spikes, users can still arbitrage against stable value collateral, but they must pay sufficient interest to justify GUILD holders voting for those loan terms.

|  Collateral Token      |  CREDIT mintable per token |  Interest Rate (% Annual)  |   Call Fee (bips)  |
| ----------- | ----------- | ----------- | -----------|
| ETH      | 2000       | 6  |  10 |
| stETH | 1700 | 5 | 25 | 
| rETH | 1700 | 5 | 25 | 
| cbETH | 1700 | 5 | 25 |
| OUSG  | 95  | 4 | 10 |
| stDAI | 96 | 3 | 5 |
| USDC | 96 | 3 | 5 |
| Univ2CREDITUSDC | .8 | 2 | 1 |
| Univ2CREDITDAI | .8 | 2 | 1 |

[^1]: Primer: Money Market Funds and the Repo Market. Viktoria Baklanova, Isaac Kuznits, Trevor Tatum. https://www.sec.gov/files/mmfs-and-the-repo-market-021721.pdf