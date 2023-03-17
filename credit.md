# Ethereum Credit Guild

Existing lending protocols like MakerDAO, Aave, and Compound rely on trusted oracles, and have "closed" governance processes where changes to parameters are forced through a central decision-making process and thus occur at a very limited rate.

The Ethereum Credit Guild seeks to change that, building an incentive aligned system with checks and balances allowing saving and credit operations without relying on trusted third parties, and responding on demand to changes in the market through an open parameter control process.

The **credit** is a decentralized debt based stablecoin, which can follow an arbitrary monetary policy, but we will assume attempts to maintain stability or strength relative to major currencies, particularly the dollar, while appreciating via a floating interest income. Due to fluctuations in the value of the underlying loan book based on market rate volatility, precise price stability in regards to a reference asset cannot be guaranteed.

- [Ethereum Credit Guild](#ethereum-credit-guild)
  - [Mechanisms](#mechanisms)
    - [Lending](#lending)
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

### Lending

A GUILD holder with above a minimum threshold of the token supply can propose a new set of lending terms. A `LendingTerm` is a blueprint for a loan.

<details>

<summary> function propose </summary>

```
// propose a new set of lending terms to governance

// require that the caller stakes at least X% of GUILD supply

// inputs:
  * the label to use for this lending term (must not be already used)
  * address of the collateral token
  * number of credits mintable per collateral token
  * interest rate in terms of credits per block
  * the last block in which this term is available
  * call fee in credits
  * auction duration in blocks
  * number of GUILD tokens to stake on the proposal

// stores the terms in a mapping uint256=>LendingTerm

function propose(uint256 termsIndex, address collateral, uint256 maxCreditsPerCollateralToken, uint256 interestRate, uint256 expiry, uint256 callFee, uint256 auctionLength, uint256 votingAmount) {
    require(terms[termsIndex].collateral == address(0)); // check that the term index has not been used
    require(votingAmount >= minQuorum); // minQuorum is a global variable controlled by governance
    // need a mechanism can be used to allow small users to coordinate their votes to meet quorum, keeping it simple for now
    terms[termsIndex].collateral = collateral;
    terms[termsIndex].maxCreditsPerCollateralToken = maxCreditsPerCollateralToken;
    terms[termsIndex].interestRate = interestRate;
    terms[termsIndex].expiry = expiry;
    terms[termsIndex].callFee = callFee;
    terms[termsIndex].auctionLength = auctionLength;

    msg.Sender.transferFrom(GUILD.address, votingAmount);
    terms[termsIndex].stakedBalances += votingAmount;
}

mapping(uint256=>LendingTerm) terms;

struct LendingTerm {
    address collateral; // the collateral token accepted
    uint256 maxCreditsPerCollateralToken; // the liquidation threshold where no call fee need be paid
    uint256 interestRate; // the interest rate per block
    uint256 expiry; // the last block at which this loan is available
    uint256 callFee; // the fee users must pay to call the loan
    uint256 totalDebt; // how many credits are outstanding under these terms
    mapping(address=>uint256) stakedBalances; // how many GUILD tokens have been staked to this lending term per user
}

```

</details>

-------------

There is a period during which other GUILD holders can dispute the loan terms.

<details>

<summary> function deny </summary>

If the loan terms are *denied*, the proposer pays a small fee in GUILD. If not denied, they optimistically become available for GUILD holders to vote for in the debt limit allocation.

```
// inputs:
  * the key to the mapping indicating the set of lending terms to vote against

function deny(uint256 terms) {
    ...
}
```

</details>

-------------

If not denied during the dispute window, any GUILD holder can vote for that loan term to increase its debt ceiling (whoever proposed it is voting for it by default, so the starting debt ceiling will be at the proposal threshold until users allocate away).

<details>

<summary> function vote </summary>

```
// inputs:
  * the key to the mapping indicating the set of lending terms to vote for
  * the amount of GUILD tokens to use for voting

function vote(uint256 terms, uint256 amountToStake) {
    ...
}
```

The global debt ceiling is determined by governance (and may be set at some constant inflation rate, or subjected to other policies). The debt ceiling of a particular loan is determined based on the amount of GUILD staked to it. For example, if the global debt ceiling is 20m credit, a holder of 10% of the GUILD supply can allocate a debt ceiling of 2m CREDIT to lend against rETH.

</details>

-------------

### Borrowing and Repayment

To initiate a loan, a user must post collateral and find an acceptable set of lending terms. Deposit can occur atomically with borrowing; withdraw requires there are no active loans against the collateral in question.

<details>

<summary> function mintAsDebt </summary>

```
// inputs:
  * the key to the mapping indicating the set of lending terms to use
  * the amount of collateral token to use

function mintAsDebt(uint256 terms, uint256 amountCollateralIn, uint256 amountToMint) {
    require(terms[terms].maxCreditsPerCollateralToken * amountCollateralIn > amountToMint);
    msgSender.transferFrom(terms[terms].collateral, amountCollateralIn);
    userPositions[msgSender][terms].collateralBalance += amountCollateralIn;
    userPositions[msgSender][terms].debtBalance += amountToMint;
    CREDIT.mint(msg.Sender, amountToMint);
}

struct userPosition {
    uint256 collateralBalance; 
    uint256 debtBalance;
    uint256 callBlock; // if the position has been called, record the block in which this occured to start the liquidation auction. A value of zero prevents liquidation.
    uint256 caller; // record who calls the loan so they can be reimbursed if the loan was underwater
}
mapping(address=>mapping(uint256=>userPosition )) userPositions; // a mapping of users to their collateral and debt balances per lending term. A user may only have one position per set of lending terms.
```

The user can mint up to the maximum amount allowed by the loan terms, with their collateral locked and unavailable for transfer or use in other loans until the loan is repaid. The protocol checks that the requested mint amount and collateral provided conform to the available terms, and if so, the user can mint CREDIT.

</details>

When a user repays their loan, they must repay a greater amount of CREDIT than they borrowed due to the accrued interest. The initial loan amount is burnt, while the profits go to the surplus buffer. Anyone can repay a loan, though only the user can withdraw their collateral. Partial repayments are allowed.

<details>

<summary> function repayBorrow </summary>

```
function repayBorrow(address user, uint256 terms, uint256 amountToRepay) {
    msgSender.transferFrom(CREDIT.address, amountToRepay);
    require(amountToRepay <= userPositions[user][terms].debtBalance); // you can't repay more than the total debt
    userPositions[user][terms].debtBalance -= amountToRepay; // reduce the position's debt accordingly
    if (userPositions[user][terms].debtBalance == 0 && userPositions[user][terms].callBlock != 0) { // if the user has fully repaid their loan, and the loan was called, make sure that no liquidation can occur by setting the call block and caller addresses to zero values. The borrower recoups the call fee.
        userPositions[user][terms].callBlock = 0;
        uint256 caller = address(0);
    }
}

```

</details>

-------------

### Calling and Liquidating Loans

Anyone can call a loan issued by the protocol by paying the call fee in either credits or GUILD.

<details>

<summary> function callPositiion </summary>

If the position's debt is larger than the `maxCreditsPerCollateralToken` defined in the loan's terms, which can only occur due to accrued interest, the call fee is waived. Otherwise, the call fee is deducted from the borrower's debt and burnt. A liquidation auction occurs to repay as much as possible of the borrower's debt by selling off as little as possible of the collateral position. If the auction reveals the loan to be insolvent, the one who triggered the auction is rewarded by being reimbursed the call fee if one was paid plus a liquidation reward. If the loan was insolvent, any GUILD holders voting for that loan's terms have their balances slashed, and the CREDIT that was lost is deducted from the surplus buffer.

```
// inputs:
   * user to call
   * which loan to call
function callPosition(address user, uint256 terms) {
    require(userPositions[user][terms].debtBalance > 0); // user must have an active loan to call
    if(userPositions[user][terms].debtBalance < terms.maxCreditsPerCollateralToken){
        msgSender.transferFrom(CREDIT.address, terms[terms].callFee); // claim the call fee from the caller if the loan is not underwater according to the issuance terms
    } 
    userPositions[user].callDate = block.number; // mark the position as called, allowing the liquidation module to act on it
    userPositions[user].caller = msgSender; // record who called the loan so they can be reimbursed if the auction reveals it is underwater and slashing occurs
}

```

</details>

<details>

<summary> function liquidateBorrow </summary>

The liquidation auction is a Dutch auction where a gradually larger portion of the borrower's collateral is offered in exchange for repaying their debt. If the borrower's entire collateral is not enough to pay their debt, a partial payment is accepted.

Consider an asset with a liquidation duration of ten minutes. The moment the loan is called, 1% of the collateral is offered for auction. By five minutes, 50% is offered. By ten minutes, all the collateral is offered. By fifteen minutes, the protocol will accept repayment of only half the debt in exchange for the full collateral position, and so on.

```
// inputs:
    * user to liquidate
    * which loan to liquidate
    * amount of collateral the liquidator wants
function liquidateBorrow(address user, uint256 terms, uint256 bid, uint256 ask) {
    // check if the bid is valid based on the loan terms and how long has passed since the loan was called
    // if the bid is valid, pull CREDIT from the caller equal to the bid, and remit to them the requested amount of the collateral token
    // if the bid is less than the borrower's full debt, the surplus buffer must be reduced accordingly
    // if the surplus buffer is marked down to a negative value, a GUILD auction is triggered
    auctionStartBlock = block.number;
}

uint256 auctionStartBlock = 0; // the start block for a guild auction. A zero value indicates there is no active auction.

```

</details>

-------------

### Handling Bad Debt

It is possible for the surplus buffer balance to become negative if a loss exceeds the buffer's starting balance. In this case, a GUILD auction is triggered, diluting the existing GUILD holders in an attempt to recapitalize the system. If this auction is insufficient to fully recapitalize the protocol, the surplus buffer is zero'd out. The goal of this mechanism is to 1) minimize any possible loss to the CREDIT holders and 2) fairly distribute any loss that does occur.

The GUILD auction is a Dutch auction where an increasing amount of GUILD is offered in exchange for enough CREDIT to replace the system's bad debt, up to some limit. It allows partial fills.

<details>

<summary> function guildAuctionBid </summary>

```
function guildAuctionBid(uint256 bidAmount) {

    // pull bidAmount of CREDIT from the user
    msgSender.transferFrom(CREDIT.address, bidAmount);
    // based on the current auction price, remit GUILD to the user
    // use this credit to reduce the surplus buffer's bad debt
    require(
        // check that surplus buffer size is not above a limit, so excess dilution does not occur
    );
    // once the bad debt is 0 or more, the auction is concluded
    if {
        // check whether the surplus buffer is >=0
        // if so, then
        auctionStartBlock = 0;
    }
}
```

</details>

GUILD holders have both an individual incentive to avoid being liquidated, and a collective incentive to prevent excessive risk taking. They earn rewards proportional to the yield they generate, and thus an honest GUILD holder will pursue the highest +EV yield opportunity available to them, while preventing others from taking risk that will create a loss larger than that individual's pro rata share of the surplus buffer.

So long as there is an honest minority of GUILD holders, reckless loans that endanger the system as a whole can be prevented, while the loans that do fail result in a decreased ownership stake for bad allocators. In the early period, GUILD emissions will compensate CREDIT holders for the risk of a relatively small surplus buffer. As the system matures over a period of several years, the size of the surplus buffer and the yield on credit will "float stably" according to market conditions.

-------------

### Surplus Buffer and Redemptions

A GUILD holder can burn their tokens for a pro rata share of the system surplus (likely with some fee) at a maximum rate of X tokens burnt per period such that this mechanism cannot destabilize the CREDIT price. In this way, the size of the surplus buffer is determined by market demand to hold GUILD vs redeem for credits.

<details>

<summary> function redeemSurplus </summary>

```

function redeemSurplus(uint256 guildToRedeem) {
    msgSender.transferFrom(GUILD.address, guildToRedeem);
    // todo check the current price per GUILD, must be manipulation resistant value
    require(surplusAvailableToRedeem >= guildToRedeem * getGUILDPrice());
    surplusAvailableToRedeem -= guildToRedeem * getGUILDPrice();
    CREDIT.transfer(msgSender, guildToRedeem * getGUILDPrice());
}

uint256 surplusAvailableToRedeem; // keep track of how much surplus is currently available for redemption, capped at X% of the CREDIT supply

uint256 lastSurplusRefill; // keep track of when the redemption buffer was last refilled

function refillRedemptionBuffer() {
    require (block.number - lastSurplusRefill > ???); // set some maximum update frequency
    lastSurplusRefill = block.number; // update the last refill block record
    surplusAvailableToRedeem = ???; // refill the buffer to the maximum
}

```

</details>


-------------

## Pricing Credit

The behavior of the CREDIT token will depend on the nature of the loan set that backs it, user interest in CREDIT, and the overall market conditions. There is no foolproof way for software to detect the quality of a collateral token or know what the market interest rate is. These inputs must be provided by humans. The goal of the Ethereum Credit Guild is to allow for market based processes with checks and balances to allow users to enagage in fair and productive lending operations without the need for trusted third parties. If the system is otherwise in equilibrium (no change in demand to hold or borrow credits, or to hold GUILD) then the value of credits will tend to increase over time as the surplus buffer accumulates credits. Based on the internal rate of return, the current value of a credit will fluctuate on the market.

The architecture of CREDIT can support arbitrary liquidity and yield properties. We can envision other versions with lower liquidity and higher yield. We expect the primary CREDIT token to have the same goals as VOLT:
* high liquidity, such that a large portion of the supply can be redeemed in the span of a week
* yield bearing equal to or better than off chain money markets

The recent USDC peg stability has made it clear that there is no such thing as a perfectly fungible, instantly portable dollar. All stablecoins, bank deposits, Paypal balances, etc have some constraints in their fungibility and transferability under certain conditions.

A traditional Peg Stability Module is possible in the architecture of CREDIT we've laid out here -- you just need a `LendingTerm` allowing minting of CREDIT 1:1 with USDC at 0% interest. This is not the desired implementation, however, instead we prefer a potentially liquidatable vault that allows for an upward drift in credit price representing the accured yield: "mint 1 credit per 1.02 USDC at 4% interest". Arbitrage does not need to be risk free, in fact, it cannot be -- if the arbitrageur is not bearing this risk, the protocol and thus the stablecoin holders are. Maintaining a small interest rate and overcollateralization on arbitrage vaults will mean sacrificing a little bit of the upward peg stability the PSM offers, in exchange for ensuring an incentive exist for new loans to be opened against productive collateral.

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