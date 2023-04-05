# Ethereum Credit Guild

Existing lending protocols like MakerDAO, Aave, and Compound rely on trusted oracles, and have "closed" governance processes where changes to parameters are forced through a central decision-making process and thus occur at a very limited rate.

The Ethereum Credit Guild seeks to change that, building an incentive aligned system with checks and balances allowing saving and credit operations without relying on trusted third parties, and responding on demand to changes in the market through an open parameter control process.

A **credit** is a decentralized debt representation, or stablecoin, which can follow an arbitrary monetary policy, but we will assume attempts to maintain stability relative to a reference asset while appreciating via a floating interest income. Due to fluctuations in the value of the underlying loan book based on market rate volatility, precise price stability in regards to a reference asset cannot be guaranteed. Credits are not `ERC4626` vault shares, but `ERC20` tokens whose price can fluctuate.

The primary debt token issued is `CREDIT`, meant to be stable in terms of major currencies, especially the dollar, and appreciate in price over time reflecting the interest paid by borrowers. Each asset that might be deposited in the protocol as collateral will also have a debt synthetic version, as in `credit_ETH` or `credit_UNI`. 

- [Ethereum Credit Guild](#ethereum-credit-guild)
  - [Mechanisms](#mechanisms)
    - [Lending Terms](#lending-terms)
    - [Borrowing and Repayment](#borrowing-and-repayment)
    - [Calling and Liquidating Loans](#calling-and-liquidating-loans)
    - [Handling Bad Debt](#handling-bad-debt)
    - [Surplus Buffer and Redemptions](#surplus-buffer-and-redemptions)
  - [Pricing Credit](#pricing-credit)
  - [Bootstrapping Credit](#bootstrapping-credit)
    - [On Competitive Advantages in Lending](#on-competitive-advantages-in-lending)
    - [Credit Genesis](#credit-genesis)

## Mechanisms

There exist two kinds of tokens in the system, the stable debt tokens such as CREDIT, and the governance and risk backstop token GUILD. GUILD holders vote to onboard new credit token denominations, approve lending terms, and allocate debt ceilings. The first two of those processes are handled through optimistic governance with veto, while debt ceiling allocation is conducted through the gauge voting with performance based rewards and slashing system that we call "market governance".

### Lending Terms

A `CreditLendingTerm` is a blueprint for a loan. It is created permissionlessly through a `LendingTermFactory` and stores information such as:

```
    // the address of the core contract which stores all system addresses
    address public core;

    address public collateralToken;
    address public borrowToken;

    // the number of credits borrowable per collateral token
    // a token whose unit value is too small will need to be handled differently, TODO
    uint256 public collateralRatio;

    // expressed as a divisor of the loan
    // an interestRate of 20 is equivalent to 5% interest (total debt / 20 per year paid in interest)
    uint256 public interestRate;

    // expressed as a divisor of the loan
    // the call fee is deducted from the borrower's debt if the loan is called
    // this protects the borrower from griefing
    uint256 public callFee;

    // how many seconds must pass between when the loan is called and the first bid can be made in the auction
    // a longer call period is better for the borrower, and more dangerous for the lender
    uint256 public callPeriod;

    // the unused debt ceiling of this lending term
    // denominated in borrowToken
    uint256 public availableCredit;

    // whether bad debt has accured resulting in slashing for voters
    bool public isSlashable;
```

GUILD holders can propose to whitelist a new term, and there is a period during which this can be vetoed.

If not denied during the dispute window, any GUILD holder can vote for that loan term to increase its debt ceiling (whoever proposed it is voting for it by default, so the starting debt ceiling will be at the proposal threshold until users allocate away).

The global debt ceiling is determined determined implicitly based on the `voteWeight` and `totalSupply` in the Guild token contract. The debt ceiling of a particular loan is determined based on the amount of GUILD staked to it. For example, if the `voteWeight` is 1, and there are 10m GUILD tokens, a holder of 10% of the GUILD supply can allocate a debt ceiling of 1m CREDIT to lend against a collateral of their choice.

-------------

### Borrowing and Repayment

To initiate a loan, a user must find an acceptable set of lending terms and post collateral. The collateral tokens are held in the associated `CreditLendingTerm` contract while the loan is active.

A given lending term mints a fixed number of credits per collateral token, until the available credit is used up. When a user repays their loan, they must repay a greater amount of credits than they borrowed due to the accrued interest. Of the repaid credits, the entire principal is burnt, while the interest is partially burnt, and partially distributed to the gauge contract where it is claimable by the GUILD holders voting for that loan. The portion of the interest that is burnt is known as the `surplusRate` and is a global governable parameter. Anyone can repay a loan, though only the user can withdraw their collateral. Partial repayments are not allowed except during the liquidation auction.

--------------

### Calling and Liquidating Loans

Anyone can call a loan issued by the protocol by paying the call fee in credits. The call fee is deducted from the borrower's debt and burnt. There is a period during which the borrower can repay but no one can bid for their collateral known as the `callPeriod`. After this, if the borrower has not repaid, anyone can trigger liquidation by sending the borrower's collateral to the `auctionHouse`. A liquidation auction occurs to repay as much as possible of the borrower's debt by selling off as little as possible of the collateral position. If the auction reveals the loan to be insolvent, the one who triggered the auction is rewarded by being reimbursed the call fee if one was paid plus a liquidation reward. If the loan was insolvent, any GUILD holders voting for that loan's terms have their balances slashed, and the CREDIT that was lost is deducted from the surplus buffer.

The liquidation auction is a Dutch auction where a gradually larger portion of the borrower's collateral is offered in exchange for repaying their debt. If the borrower's entire collateral is not enough to pay their debt, a partial payment is accepted.

The current MVP auction house has a fixed duration for auctions, but this might also be a parameter in the `CreditLendingTerm`.

-------------

### Handling Bad Debt

Existing decentralized finance protocols like Aave, Compound, or MakerDAO lack mechanisms to swiftly mark down bad debt and prevent bank runs. Users who withdraw (in the case of Aave or Compound) or redeem via the Peg Stability Module (in the case of MakerDAO) can avoid any loss, while those who are too slow risk a 100% loss.

We mitigate this risk by eliminating atomic, on demand withdrawals, in favor of the mechanic of callable loans. Most loans will have a call period during which the borrower can repay. A loan may have a call period of zero to simulate the function of a PSM or Compound pool, but since liquidation occurs by auction, it will still set a market price instead of allowing some users to redeem above peg after a loss has occurred.

This alone does not solve bank run risk, as when partial repayment is accepted in a liquidation auction, there are more credits in circulation compared to the amount of credit owed as debt, and so the 'leftover' credits are worthless if all the loans are called or repaid. This is addressed by separately tracking the circulating credit supply, and the total credits issued as debt. When the ratio is not 1:1, the amount of credits minted against collateral or required to repay debts is adjusted accordingly, such that if the entire protocol is unwound, every credit must be used to repay the outstanding loans, and more credits can be issued against the same collateral proportional to the bad debt. The above is true for each credit denomination, meaning bad debt in one denomination will be transparently marked down and legibile throughout the protocol as a whole.

-------------

### Surplus Buffer and Redemptions

GUILD holders can take profits by burning GUILD for a share of the surplus buffer in any denomination of their choice. This mechanism is rate limited such that it cannot destabilize the prices of various credit tokens. The objective of this mechanism is to facilitate a market based rate for each denomination of credit, which is discussed below, and allow the market to determine the optimal size for the surplus buffer. A GUILD price higher than the intrinsic value implies the system is growing and should increase its first loss capital supply, and the intrinsic value provides a gradually increasing floor price for GUILD barring losses from bad loans. A GUILD price lower than the intrinsic value implies the system is stable or shrinking and should allow capital to exit freely.

-------------

## Pricing Credit

The behavior of the each credit token will depend on the nature of the loan set that backs it, user interest in CREDIT, and the overall market conditions. There is no foolproof way for software to detect the quality of a collateral token or know what the market interest rate is. These inputs must be provided by humans. The goal of the Ethereum Credit Guild is to allow for market based processes with checks and balances to allow users to enagage in fair and productive lending operations without the need for trusted third parties. If the system is otherwise in equilibrium (no change in demand to hold or borrow credits, or to hold GUILD) then the value of credits will tend to increase over time as the surplus buffer accumulates credits. In reality, the current value of a credit will fluctuate on the market based on net buy and sell demand, as well as changes in the overall market risk and interest environment.

The architecture of the Ethereum Credit Guild can support arbitrary liquidity and yield properties. We can envision other versions with lower liquidity and higher yield. We expect the primary CREDIT token to have the same goals as VOLT:
* high liquidity, such that a large portion of the supply can be redeemed in the span of a week
* yield bearing equal to or better than off chain money markets

Likewise, the various denominations like `credit_ETH` or `credit_OP` should seek to preserve robust liquidity and minimal risk, while opening new and better lending and borrowing opportunities onchain.

The recent USDC peg stability has made it clear that there is no such thing as a perfectly fungible, instantly portable dollar. All stablecoins, bank deposits, Paypal balances, etc have some constraints in their fungibility and transferability under certain conditions. All of these are synthetic assets, for no bank deposit is fully backed by cash. 

A traditional Peg Stability Module is possible in the architecture of CREDIT we've laid out here -- you just need a `LendingTerm` allowing minting of CREDIT 1:1 with USDC at 0% interest, a call fee of 0, and a call period of 0. This is not the desired implementation, however, instead we prefer a potentially liquidatable vault that allows for an upward drift in credit price representing the accured yield: "mint 1 credit per 1.02 USDC at 4% interest". Arbitrage does not need to be risk free, in fact, it cannot be -- if the arbitrageur is not bearing this risk, the protocol and thus the stablecoin holders are. Maintaining a small interest rate and overcollateralization on arbitrage vaults will mean sacrificing a little bit of the upward peg stability the PSM offers, in exchange for ensuring an incentive exist for new loans to be opened against productive collateral The key difference between this mechanism and a Maker-style PSM is that it must still undergo a "liquidation auction" to be redeemed against, meaning it is resilient to bank runs, since a market pricing occurs where multiple parties will have a fair chance to bid.

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