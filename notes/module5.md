# Uniswap V2

## 1. Uniswap V2 Architecture: An Introduction to Automated Market Makers

Instead of using traditional order books to match buyers and sellers, Automated Market Makers (AMMs) allow users to trade directly against a smart contract pool containing two assets (Token $X$ and Token $Y$).

### 1. The Constant Product Formula
When a user trades, they withdraw one token and deposit the other. This is governed by the **Constant Product Formula**, which ensures the "total" product of the pool's assets never decreases:
$$ x \cdot y \le x' \cdot y' $$
*(Balances before trade $\le$ Balances after trade)*

Because pools charge a **trading fee** on every swap, the $x \cdot y$ product actually *increases* slightly after every trade. 

### 2. Liquidity Providers (LPs)
Users who supply the assets ($X$ and $Y$) to the pool are **Liquidity Providers**. 
- They receive **LP Tokens** in return (similar to ERC-4626 vault shares, but tracking two assets).
- As trading fees continually grow the pool's total product ($x \cdot y$), the underlying value of each LP Token steadily increases.

### 3. Pros and Cons of AMMs

Because AMMs operate purely on mathematical ratios rather than order books, they come with a unique set of trade-offs:

#### The Advantages
- **No Bid-Ask Spread:** You never have to wait for a matching buyer/seller to execute a trade.
- **Gas Efficiency:** Executing a simple math formula is vastly cheaper on-chain than maintaining and sorting a massive limit order book.
- **Built-in Oracles:** Because the price is entirely dictated by the ratio of the pool's assets, the AMM itself doubles as a decentralized price oracle for other smart contracts.
- **Automatic Price Discovery:** The **spot price** of Token $x$ is simply: $ \text{price}(x) = \frac{\text{Holdings}_y}{\text{Holdings}_x} $ *(If the internal pool price strays from the global market, arbitrageurs will immediately exploit the difference to naturally rebalance the pool).*

#### The Drawbacks
- **Constant Price Movement (High Slippage):** Because *every* trade alters the ratio of the pool, the price is constantly moving. Even small orders move the price, causing significantly more slippage than traditional order books.
- **Sandwich Attacks:** Because slippage is mathematically guaranteed and visible in the public mempool, AMMs are highly susceptible to MEV sandwich attacks. 
  - *Note: To combat this, the industry is rapidly moving toward **Intent-Based Routing** (e.g., UniswapX) and **Private RPCs / ZK Dark Pools**, which bypass the public mempool entirely so MEV bots cannot spy on and front-run trades.*
- **Loss of Pricing Control:** Liquidity Providers cannot dictate the price their assets are sold at; they are entirely at the mercy of the mathematical formula.
- **Impermanent Loss:** As the pool's ratio shifts due to trading, Liquidity Providers may suffer from "impermanent loss" (meaning their deposited assets would have been worth more if they had simply held them in their wallet rather than providing liquidity).

### 4. Smart Contract Architecture
The entire Uniswap V2 system is surprisingly simple, driven by just three core smart contracts:

1. **[The Factory](https://github.com/Uniswap/v2-core/blob/master/contracts/UniswapV2Factory.sol):** A permissionless registry used to deploy new Pair contracts. 
2. **[The Pair](https://github.com/Uniswap/v2-core/blob/master/contracts/UniswapV2Pair.sol):** The actual AMM. Each unique pair of tokens (e.g., ETH/USDC) has its own dedicated Pair contract that holds the assets. The Pair contract *itself* is an ERC-20 token, minting LP tokens to track user deposits.
3. **[The Router](https://github.com/Uniswap/v2-periphery/tree/master/contracts):** A convenience wrapper. Instead of interacting with Pair contracts directly, most users interact with the Router, which handles complex logic like routing a single trade through multiple intermediate pairs if a direct pair doesn't exist.

> **The Core-Periphery Pattern:** This clean separation between the Factory/Pair (the "Core") and the Router (the "Periphery") is a standard smart contract design pattern. It keeps the core logic minimal, un-upgradable, and highly secure, while allowing complex, evolving user-facing logic to live safely on the periphery.

### Locating a Pool via CREATE2
Because reading from storage is extremely gas-intensive, Uniswap V2 does not use a massive state variable mapping (like `mapping(address => mapping(address => address))`) to look up the address of a specific Pair contract.

Instead, the Factory deploys every new Pair using the **CREATE2** opcode. This allows smart contracts to deterministically calculate the exact address of *any* pool entirely within memory, without making a single external call or touching state storage.

Here is the exact `pure` helper function Uniswap uses to calculate a pair's address, saving massive amounts of gas:

```solidity
// calculates the CREATE2 address for a pair without making any external calls
function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
    (address token0, address token1) = sortTokens(tokenA, tokenB);
    pair = address(uint160(uint(keccak256(abi.encodePacked(
            hex'ff',
            factory,
            keccak256(abi.encodePacked(token0, token1)),
            hex'96e8ac4277198f8fbbf785487aa39f430f63b76db002cb326e37da348845f' // init code hash
    )))));
}
```

## 2. Calculating the Settlement Price of an AMM Swap

### The Constant Product Formula
The entire pricing mechanism of a Uniswap V2 pool is derived from one fundamental rule: a trade can never decrease the total product of the pool's reserves ($k$).

In practice, the smart contract enforces this by comparing the product before and after a swap:
$$ k_{\text{before}} \le k_{\text{after}} $$

Expanding this out to the actual token balances:
$$ x_{\text{before}} \times y_{\text{before}} \le x_{\text{after}} \times y_{\text{after}} $$

> **Why the $\le$ (less than or equal to) sign?** 
> 1. Uniswap charges a trading fee, meaning $k_{\text{after}}$ will organically grow slightly on every trade.
> 2. Uniswap does not stop users from accidentally giving the AMM more tokens than they need to. If a user inputs a bad trade, the pool simply absorbs the excess capital, pushing $k_{\text{after}}$ higher.

### Calculating the Swap Output ($\Delta y$)
If a trader wants to deposit a specific amount of Token X ($\Delta x$), how much of Token Y ($\Delta y$) will they receive in return? 

By manipulating the constant product formula and factoring in Uniswap V2's standard **0.3% trading fee**, the exact math for calculating the maximum swap output is:

$$ \Delta y \le y - \left( \frac{x \cdot y}{x + (\Delta x \cdot 99.7\%)} \right) $$

Where:
- $x$ and $y$ are the total pool reserves *before* the swap.
- $\Delta x \cdot 99.7\%$ is the amount of tokens deposited into the AMM *after* the 0.3% fee is deducted.
- $\Delta y$ is the maximum amount of tokens swapped out of the AMM.

> **The Slippage Curve:** Notice how $\Delta x$ is in the denominator. Because of the mathematical curve created by this formula, the more $\Delta x$ you dump into the pool in a single trade, the worse your execution price becomes. The ratio shifts aggressively against you as the trade executes, meaning **larger trades get proportionally less output.**

## 3. Breaking Down the Uniswap V2 Swap Function

At the heart of the `UniswapV2Pair.sol` contract is the `swap` function. It is a low-level function, meaning it expects the Router contract to have already performed safety checks (like ensuring the user actually sent the input tokens). 

Here is the exact source code, with a breakdown of its core mechanics:

```solidity
// this low-level function should be called from a contract which performs important safety checks
function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
    require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
    (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
    require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

    uint balance0;
    uint balance1;
    { // scope for _token{0,1}, avoids stack too deep errors
    address _token0 = token0;
    address _token1 = token1;
    require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
    
    // 1. Optimistic Transfers
    if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
    if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
    
    // 2. Flash Swap execution (if data is passed)
    if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
    
    balance0 = IERC20(_token0).balanceOf(address(this));
    balance1 = IERC20(_token1).balanceOf(address(this));
    }
    
    // 3. Calculate how much was sent IN
    uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
    uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
    require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
    
    { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
    
    // 4. Adjust balances for the 0.3% fee
    uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
    uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
    
    // 5. The Constant Product Check (k_after >= k_before)
    require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
    }

    _update(balance0, balance1, _reserve0, _reserve1);
    emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
}
```

### Key Mechanics of the Swap:
1. **Optimistic Transfers:** Notice how Uniswap actually sends the requested output tokens to the user *before* it even checks if the user paid for them! 
2. **Flash Swaps (Flash Borrowing):** Because of the optimistic transfer, if the user provides `data`, Uniswap pauses execution and calls `uniswapV2Call` on the receiving smart contract. This allows the user to execute arbitrary logic (like an arbitrage trade) using the un-paid-for tokens. However, the receiving contract *must* pay the tokens back (plus fees) before the transaction ends, otherwise the `K` requirement will fail. *(Note: To use this feature, the swap must be executed by a custom smart contract, not an EOA).*
3. **Calculating Inputs (Fees on Tokens In):** Once control is returned to Uniswap, it simply checks its current `balanceOf` to see how much the user eventually deposited. An important nuance here is that **you pay fees on the tokens you send IN, not on the tokens you receive OUT.** 
4. **Accounting for Fees (The `K` Requirement):** The contract calculates the `Adjusted` balances by mathematically deducting the 0.3% fee from the tokens sent in. Finally, it enforces the Constant Product Formula. The protocol doesn't just want $K$ to get larger; it specifically enforces that $K$ gets larger *by at least an amount that accounts for the 0.3% fee*. If $k_{\text{after}}$ is less than $k_{\text{before}}$, the entire transaction safely reverts.

### What can go wrong? (The lack of Safety Checks)
Because `swap()` is a raw, low-level function, it lacks basic safety rails. There are two major things that can go wrong if called directly:
1. **You might accidentally overpay:** The contract does not check if your `amountIn` was optimal. If you send way too many tokens into the contract, the AMM simply absorbs the excess (pushing $K$ higher) and you lose that capital permanently. 
2. **You might waste gas on reverts:** The `amountOut` parameters are strictly fixed. If the tokens you sent in turn out to be insufficient to cover the requested `amountOut` due to slippage, the transaction will simply revert at the very end (during the `K` check), completely wasting your gas. 

*(This is exactly why normal users should never call `pair.swap()` directly, but instead route their trades through the **Router** contract, which acts as a safety layer by handling slippage protection and optimal input amounts!)*

## 4. Uniswap V2 Mint and Burn Functions

### The Burn Function (Removing Liquidity)
When a Liquidity Provider decides to exit the pool, they burn their LP tokens in exchange for the underlying assets. The math here is strictly proportional based on their share of the total supply. 

**The Burn Calculation:**
The amount of underlying tokens returned is calculated exactly as: `Liquidity Burned / Total LP Supply`. 
For example, if the total supply of LP tokens is 1,000, and a user burns 100 LP tokens, they will receive exactly **10%** of the `token0` and **10%** of the `token1` currently held by the pool.

**The Slippage Risk:**
It is critical to remember that the pool's ratio of `token0` to `token1` can change between the moment you sign the burn transaction and the moment it is confirmed on-chain (due to other swaps happening in the mempool). Because of this, you might withdraw a significantly different split of the two tokens than you originally anticipated.

### The Mint Function (Adding Liquidity)
When adding liquidity, the protocol strictly enforces that you cannot change the current price ratio of the pool. 

**The Mint Calculation:**
To enforce this, the smart contract calculates the number of LP tokens to mint based on the *worse* of the two token deposit ratios. 

Mathematically, it calculates both:
1. `(amount0 / _reserve0) * totalSupply`
2. `(amount1 / _reserve1) * totalSupply`

...and mints the **minimum** of the two. 

The fact that the user will always get the worse of the two ratios heavily incentivizes them to deposit `token0` and `token1` in the exact perfect ratio of the current pool. If they provide an imperfect ratio, the AMM simply absorbs the excess tokens as a free donation to the pool without giving the user any extra LP shares!

### What can go wrong? (The lack of Safety Checks)
Just like the low-level `swap` function, calling the low-level `mint` function directly is extremely dangerous because it lacks basic slippage protections:

1. **Supply Ratio Safety Check:** The low-level `mint` function does not check if the pool's ratio drastically shifted while your transaction was pending in the mempool. If you send tokens expecting a 50/50 ratio, but a massive trade occurs right before your transaction, the ratio could shift to 80/20. Because `mint` always gives you the *minimum* of the two ratios, the pool will absorb your now "incorrect" ratio and you will lose capital.
2. **TotalSupply Safety Check:** The low-level `mint` function does not allow you to specify a minimum amount of LP tokens you expect to receive. If the `totalSupply` or reserves fluctuate wildly before your transaction lands, you might mint far fewer LP tokens than your capital was actually worth. 

*(Once again, the **Router** contract solves this by providing `amount0Min`, `amount1Min`, and `amountTokenMin` parameters when adding/removing liquidity, ensuring the transaction safely reverts if the pool ratio or LP token output falls below your acceptable threshold).*

### The Initial Minter: Why Liquidity is $\sqrt{k}$
When a pool is first created, there is no `totalSupply` of LP tokens to use as a baseline for proportional math. For the **very first depositor**, Uniswap calculates the amount of LP tokens to mint using the geometric mean of the deposited assets:

$$ \text{Initial LP Tokens} = \sqrt{x \cdot y} = \sqrt{k} $$

**Why $\sqrt{k}$?** 
It ensures that the value of an LP token grows linearly with the overall size of the pool, regardless of the initial price ratio. If a pool is created with 4 times as much liquidity, $k$ becomes 16 times larger, but $\sqrt{k}$ becomes exactly 4 times larger, correctly minting 4 times as many LP tokens.

### The First Minter Problem (Inflation Attack)
Because of how Ethereum handles integer division (always rounding down to the nearest whole number), AMMs are vulnerable to a brutal exploit called the **First Minter Problem** (or Inflation Attack).

An attacker could:
1. Be the first minter and deposit tiny amounts (e.g., 1 wei of `token0` and 1 wei of `token1`), minting exactly 1 wei of an LP token.
2. Directly transfer (donate) massive amounts of `token0` and `token1` into the pair contract.
3. This artificially inflates the underlying value of their single 1 wei LP token to an astronomical price.
4. When a normal user tries to deposit liquidity, the formula `(amount / reserve) * totalSupply` evaluates to a fraction (e.g., `0.99`). Because Solidity truncates fractions to `0`, the user mints `0` LP tokens, and their deposited capital is completely stolen and absorbed by the attacker's 1 wei LP token.

**Uniswap's Solution:**
To completely prevent this attack, Uniswap V2 forcibly burns the first **1000 wei** of LP tokens by permanently locking them inside `address(0)`. 
- Because those tokens can never be redeemed, no one can ever own 100% of the pool.
- It forces the minimum value of `totalSupply` to be at least 1000, making it astronomically expensive (requiring millions of dollars of upfront capital) for an attacker to artificially inflate the pool enough to successfully exploit the rounding error.

## 5. How Uniswap V2 Computes the mintFee

### The Protocol Fee Switch
When Uniswap V2 was built, the developers hardcoded a mechanism allowing the protocol to collect a fraction of the trading fees for itself (specifically routing them to a designated fee receiver address). 

- The standard trading fee on every swap is **0.3%**.
- The protocol fee is designed to collect exactly **1/6th** of that swap fee. 
- Therefore, if activated, the protocol would siphon off exactly **0.05%** of every trade, leaving the remaining 0.25% for the Liquidity Providers.

*(Note: Although this specific `mintFee` switch was never actually activated on the main Ethereum Uniswap V2 deployment, it is crucial to understand the math because countless Uniswap forks—like SushiSwap and PancakeSwap—do actively use this mechanism!)*

### Computing the `mintFee`: Core Assumptions
Because the 0.3% fee isn't "sent" anywhere during a swap, but rather absorbed into the pool to grow $K$, the protocol needs a clever way to figure out how much of that growth it is entitled to. 

To calculate the protocol's 1/6th cut, Uniswap V2 relies on two critical invariants:
1. **Liquidity Only Grows Between Mints/Burns:** If `mint()` or `burn()` are not currently being called, the underlying liquidity ($K$) of the pool can only increase.
2. **Growth = Fees:** Any increase in liquidity between these events is purely due to accumulated trading fees (or direct donations).

Therefore, by snapshotting the pool's liquidity at the end of every `mint()` or `burn()` transaction, and then measuring the increase in liquidity the very next time `mint()` or `burn()` is called, the pool can perfectly calculate exactly how much fee value was generated during that time gap!

Based on this calculation, **right before** executing the actual user's `mint()` or `burn()`, Uniswap actively mints brand new LP tokens and sends them directly to the protocol fee recipient. By extracting its 1/6th cut in the form of LP shares rather than raw underlying tokens, the protocol minimizes gas-heavy external transfers and simplifies the accounting.

### Deriving the `mintFee` Formula
To calculate exactly how many LP tokens to mint to the protocol, Uniswap relies on a strict mathematical derivation. Let's define the notation:

- $s$: The total supply of LP tokens *before* the dilutive protocol fee LP tokens are minted.
- $\eta$: The amount of new LP tokens that will be minted to the protocol. This must be exactly enough to redeem 1/6th of the profit liquidity.
- $\ell_1$: The liquidity of the original deposit (the liquidity the LPs originally provided).
- $\ell_2$: The total current liquidity (the original deposits *plus* the new liquidity generated from swap fees).
- $d$: The amount of liquidity owed to the LPs, net of the protocol fee. The LPs are entitled to their original deposit ($\ell_1$) plus 5/6ths of the profit.
- $p$: The amount of liquidity owed to the protocol. This is exactly 1/6th of the profit: $\frac{1}{6}(\ell_2 - \ell_1)$.

To accurately compute $\eta$, the contract relies on this core invariant:

$$ \frac{\eta}{p} = \frac{s}{d} $$

In plain English: The ratio of the protocol's new LP tokens ($\eta$) to the liquidity it is owed ($p$) must be perfectly equal to the ratio of the existing LP tokens ($s$) to the liquidity the LPs are owed ($d$).

## 6. How the TWAP Oracle in Uniswap v2 Works

### The Danger of Spot Prices & TWAP
Relying on the current "spot price" (the simple ratio of reserves) is extremely unsafe. Flash loans allow attackers to borrow massive capital and violently skew the pool's ratio within a single transaction to manipulate consuming protocols. 

To solve this, Uniswap uses a **TWAP** (Time-Weighted Average Price). Because a flash loan only exists within a single block, averaging the price over time completely neutralizes the attack. An attacker would have to leave millions of dollars exposed across multiple blocks to skew the average, which arbitrageurs would immediately steal.

### UQ112.112: Storing the Price
Because Solidity lacks decimals, Uniswap V2 defines price using a custom **UQ112.112** fixed-point format:
- **112 bits** for the integer.
- **112 bits** for the fractional precision.

This highly optimized 224-bit number is packed perfectly alongside a **32-bit timestamp** to fit into a single 256-bit storage slot, saving massive amounts of gas.

### How TWAP is Calculated
Instead of storing a gas-heavy array of historical prices, Uniswap mathematically optimizes the process: **it does not store any lookback windows or denominators.** 

The solution is that Uniswap **only stores the numerator** of the average formula. Every single time the liquidity ratio changes (via `mint`, `burn`, `swap`, or `sync`), it calculates how long the *previous* price lasted, multiplies it by that price, and adds it to a single running tally (`priceCumulativeLast`).

To find the average price across a specific duration, external contracts must take a snapshot of the accumulator at two different times and use the following mathematical formula:

$$ \text{time-weighted average price} = \frac{P_1T_1 + P_2T_2 + \cdots + P_nT_n}{\sum_{i=1}^{n} T_i} $$

Because the numerator ($P_1T_1 + \dots$) is simply the difference between the two accumulator snapshots, the consuming contract just divides that difference by the total time elapsed (providing its own denominator) to get a perfectly weighted average!

### Limiting the Lookback Window
Because Uniswap pushes the responsibility of the denominator onto the consuming contract, that contract must make a critical architectural decision: **How long should the lookback window be?**

This creates a strict security tradeoff:
- **Too Short (e.g., 10 minutes):** The oracle is highly responsive and tracks the true spot market very closely. However, it is much cheaper and easier for a well-capitalized attacker to sustain price manipulation over a brief 10-minute window.
- **Too Long (e.g., 7 days):** The oracle is completely impervious to manipulation (an attacker would go bankrupt trying to hold the price down against arbitrageurs for a week). However, the price is heavily lagged. If the asset suddenly crashes 50% in one day, the 7-day TWAP will still report an artificially high price, potentially causing catastrophic bad debt in a lending protocol.

Most major DeFi protocols choose a balanced lookback window ranging between **30 minutes and 24 hours**, depending heavily on the liquidity depth of the specific token pair.

### Overflowing the 32-bit Timestamp
A 32-bit Unix timestamp will overflow and reset to zero in the year **2106**. However, because Uniswap V2 was written in Solidity 0.5.16 (which naturally wraps math), this isn't an issue. If a consuming contract uses `unchecked` subtraction for `Time2 - Time1`, the binary overflow perfectly cancels itself out to yield the correct elapsed seconds!

## 7. UniswapV2Library Code Walkthrough
The `UniswapV2Library` is a stateless helper contract used to calculate precise swap math *before* executing trades.

### 1. `getAmountOut()` & `getAmountIn()`
These two functions calculate exact single-hop swap outputs based on the $x \cdot y = k$ invariant. 

By algebraically isolating $\Delta y$ from the equation $xy = (x + \Delta x)(y - \Delta y)$, the library derives the exact output formula:

$$ \Delta y = \frac{y \Delta x}{x + \Delta x} $$

Because the library must factor in the 0.3% trading fee without using decimals, it uses a clever fractional trick: it multiplies the input amount by **997** and the existing reserves by **1000**, which perfectly maintains the mathematical ratio while extracting the fee!

`getAmountIn()` uses the exact same algebra solved backward to find the required input for a desired output.

### 2. `getAmountsOut()` & `getAmountsIn()`
Very rarely do users swap across a single pool. Often, they execute "multi-hop" swaps (e.g., Token A $\rightarrow$ Token B $\rightarrow$ Token C).

Instead of making the user calculate the math for every jump, `getAmountsOut()` takes an array of token paths. It simply loops through the path, mathematically passing the exact calculated `amountOut` of the first pool directly into `getAmountOut()` as the `amountIn` for the next pool.

This elegantly chains the algebraic calculations together, telling the Router exactly how many output tokens will emerge at the very end of a massive multi-hop path!

### 3. `getReserves()`
`getReserves()` is a powerful helper function. Given two token addresses, it uses `CREATE2` to dynamically calculate the pool's address, queries the raw reserves, and automatically sorts them. This guarantees `reserveA` perfectly aligns with `tokenA`, abstracting all the messy numeric sorting logic away from the Router!

### 4. `quote()`
The `quote()` function calculates the equivalent value of an asset based purely on the current ratio of the reserves (ignoring trading fees and slippage). 

$$ price(\text{foo}) = \frac{reserve(\text{bar})}{reserve(\text{foo})} $$

It is used exclusively to calculate the perfect ratio of Token A to Token B when adding liquidity. 
**WARNING:** Because `quote()` returns the pure spot price, it is entirely vulnerable to flash loan manipulation. It must *never* be used as an on-chain price oracle!

## 8. Uniswap v2 router code walkthrough

### The Role of the Router
The `UniswapV2Pair` core contracts are incredibly low-level and intentionally strip out safety checks to save gas. They are not meant to be interacted with directly by normal users.

Instead, the **Router** acts as the primary user-facing smart contract, wrapping the core contracts in essential safety and quality-of-life logic. The Router provides five critical functionalities:

1. **Safe Liquidity Management:** Safely routing user funds to mint and burn LP tokens.
2. **Safe Swapping:** Executing trades (including complex multi-hop paths) smoothly.
3. **Native ETH Integration:** Automatically wrapping/unwrapping raw Ether (ETH) into WETH behind the scenes so users don't have to manually interact with the WETH ERC20 contract before trading.
4. **Slippage Protection:** Implementing strict `amountOutMin` and deadline checks (which are completely omitted from the core Pair contracts) to protect users from MEV sandwich attacks and stalled transactions.
5. **Fee-on-Transfer Support:** Explicitly supporting tokens that take a "tax" on transfer (like deflationary meme coins) by verifying the exact amounts received *after* the tax is taken, rather than trusting the pre-transfer parameters.

*(Note: Uniswap originally launched with `UniswapV2Router01`, but quickly discovered that fee-on-transfer tokens were breaking the swap math. They subsequently deployed `UniswapV2Router02`, which is functionally identical to `Router01` but introduces specific `SupportingFeeOnTransferTokens` functions to safely handle these deflationary edge cases.)*

### Swapping Tokens: Exact In vs. Exact Out
When swapping standard ERC20 tokens, the Router provides two distinct paths depending on where the user wants to place their slippage risk:

#### 1. `swapExactTokensForTokens`
- **The Intent:** "I have exactly 100 Token A to spend. Give me as much Token B as possible."
- **Slippage Protection:** `amountOutMin`. Because the input is fixed, the user is vulnerable to the output fluctuating. If MEV bots manipulate the pool causing the output to drop below `amountOutMin`, the Router aggressively reverts the entire transaction.
- **Under the Hood:** The Router calculates the expected output using the library, verifies it meets the minimum threshold, transfers the exact input from the user to the first pool, and calls `_swap` to chain the tokens down the path to the user's destination.

#### 2. `swapTokensForExactTokens`
- **The Intent:** "I need exactly 100 Token B to emerge at the end. Pull whatever Token A is required from my wallet to make it happen."
- **Slippage Protection:** `amountInMax`. Because the exact output is demanded, the user is vulnerable to the *input cost* skyrocketing. If MEV manipulation causes the required input to exceed `amountInMax`, the Router reverts.
- **Under the Hood:** The Router uses `getAmountsIn` (solving the algebraic math backward) to figure out exactly how much input is required *right now* to achieve the demanded output, verifies it doesn't exceed the user's max budget, pulls that calculated input, and executes the swap.

### The Internal `_swap()` Engine
Whether you are executing an "exact in" or an "exact out" trade, the Router ultimately relies on its internal `_swap()` function to physically move the tokens. 

This function contains the core `for` loop responsible for chaining multi-hop trades (e.g., Token A $\rightarrow$ Token B $\rightarrow$ Token C) with extreme gas efficiency.

Once the initial input tokens are sent to the very first Pair contract, the `_swap()` loop executes the following logic for every hop in the path:
1. It determines the address of the *next* Pair contract in the sequence (or the user's wallet address if it is the final hop).
2. It determines exactly how much of `token0` or `token1` should be outputted from the current Pair.
3. It calls the low-level `swap()` function on the current Pair contract, instructing it to send those output tokens **directly to the destination address determined in Step 1**.

**Why is this brilliant?**
The tokens never touch the Router contract during intermediate hops! If you are swapping A $\rightarrow$ B $\rightarrow$ C, Pool 1 sends Token B directly into Pool 2. Pool 2 then sends Token C directly to the user. By bypassing the Router entirely during the physical transfers, Uniswap saves massive amounts of gas.

### The `_addLiquidity` Calculation
When a user wants to provide liquidity, they pass in `amountADesired` and `amountBDesired`. However, because the pool's ratio dictates the market price, new liquidity must be added in the *exact same ratio* as the current reserves. 

The Router uses the internal `_addLiquidity()` function to mathematically calculate the optimal deposit amounts without exceeding the user's desired budget:

1. **Creating the Pool:** If the Pair contract doesn't exist yet, the Router dynamically deploys it using the Factory.
2. **Initial Liquidity:** If the pool is completely empty, the user's `Desired` amounts are accepted as-is, because their deposit permanently establishes the initial ratio of the pool.
3. **Matching Ratios:** If the pool already has reserves, the Router uses the library's `quote()` function to calculate how much Token B is mathematically required to perfectly match `amountADesired`.
   - If `amountBOptimal <= amountBDesired`, the user provided enough Token B budget! The function locks in `amountADesired` and `amountBOptimal`.
   - If `amountBOptimal > amountBDesired`, the user's Token B budget is too small to match all of their Token A. The Router flips the math: it calculates how much Token A is required to perfectly match `amountBDesired`. It then locks in `amountAOptimal` and `amountBDesired`.

Once these exact, ratio-perfect amounts are calculated, the outer user-facing `addLiquidity` function safely pulls those precise amounts from the user, sends them to the pool, and calls the low-level `mint()` function to issue the LP tokens!

### `addLiquidity()` & `addLiquidityETH()`
These are the primary user-facing functions that execute the physical deposit.

#### 1. `addLiquidity()`
This function orchestrates standard ERC20/ERC20 deposits:
1. It calls `_addLiquidity()` to calculate the exact optimal amounts of Token A and Token B.
2. It uses `SafeERC20` to securely transfer those exact amounts from the user's wallet directly into the Pair contract.
3. It calls the low-level `mint()` function on the Pair contract, passing in the user's address so they receive the newly minted LP tokens.

#### 2. `addLiquidityETH()`
This function orchestrates ERC20/ETH deposits, automatically handling the messy process of wrapping Ether. It is marked `payable` so users can attach raw ETH directly to the transaction.
1. It calls `_addLiquidity()` to calculate the exact optimal amounts of the ERC20 Token and ETH required.
2. It safely transfers the exact amount of the ERC20 token from the user to the Pair contract.
3. It takes the required amount of raw ETH from `msg.value`, deposits it into the WETH contract (wrapping it), and sends that newly-minted WETH directly to the Pair contract.
4. It calls `mint()` to issue the LP tokens to the user.
5. **The Refund:** If the optimal ratio calculation required *less* ETH than the user actually attached in `msg.value`, the Router automatically refunds the excess raw ETH back to the user's wallet!

### Removing Liquidity & Permits
When users want to cash out their LP tokens and reclaim their underlying assets, the Router provides several helper functions.

#### 1. `removeLiquidity()` & `removeLiquidityETH()`
`removeLiquidity` simply pulls the LP tokens from the user, sends them to the Pair contract, and calls the low-level `burn()` function. 

`removeLiquidityETH` is a wrapper that actually calls `removeLiquidity` under the hood. It receives the underlying ERC20 token and WETH from the burned LP tokens. It safely transfers the ERC20 token to the user, but intercepts the WETH, unwraps it back into raw ETH, and sends the raw ETH directly to the user's wallet.

#### 2. `removeLiquidityWithPermit()`
Normally, to interact with the Router, a user must first submit a separate `approve()` transaction to the ERC20 contract granting the Router permission to spend their tokens, and *then* submit the actual Router transaction. This creates bad UX and requires two separate gas fees.

However, Uniswap V2 LP tokens natively implement **ERC2612 Permits**. This allows a user to cryptographically sign an approval message off-chain. 
The user can pass this signature directly into `removeLiquidityWithPermit()`. The Router will verify the signature, instantly grant itself allowance, and burn the LP tokens all within a **single transaction**! 

*(Naturally, `removeLiquidityETHWithPermit()` does exactly the same thing, but additionally handles unwrapping the resulting WETH into raw ETH).*

### Router02: Supporting Fee-On-Transfer Tokens
When Uniswap V2 originally launched with `Router01`, deflationary "fee-on-transfer" tokens (meme coins that burn 2% of every transaction) broke the internal math.

In a standard swap, the Router mathematically calculates that sending 100 Token A should yield 50 Token B. It sends 100 Token A to the pool, and tells the pool to execute the swap. 
However, if Token A has a 2% tax, the pool actually only receives 98 tokens. When the Router subsequently instructs the pool to execute the swap expecting 100 input tokens, the pool's $x \cdot y = k$ mathematical invariant instantly fails, and the entire transaction reverts.

To fix this, Uniswap deployed `Router02`, which introduced new functions appended with `SupportingFeeOnTransferTokens`.

Instead of relying on pre-calculated theoretical math, these functions use an empirical **balance-checking** approach:
1. They check the pool's balance of Token A *before* the transfer.
2. They execute the physical transfer.
3. They check the pool's balance of Token A *after* the transfer.
4. They subtract the difference.

This difference represents the *exact* number of tokens that safely arrived inside the pool after the deflationary tax was extracted. The Router then feeds this true, post-tax number into the swap math, ensuring the $k$ invariant perfectly balances and the transaction succeeds!

### Wrappers Around the `UniswapV2Library`
At the very bottom of the Router contract, you will find several `public view` and `public pure` functions, including:
- `quote()`
- `getAmountOut()` / `getAmountIn()`
- `getAmountsOut()` / `getAmountsIn()`

These functions contain no unique logic of their own. They are simple wrappers that forward the arguments directly to the underlying `UniswapV2Library` contract and return the result.

**Why does the Router do this?** 
Pure developer convenience. Instead of forcing every frontend developer or external smart contract to import, compile, and call the `UniswapV2Library` directly just to calculate trade math, the Router exposes them natively. This allows developers to treat the Router as a singular "one-stop-shop" API: they query the Router to calculate the expected price, and then send the physical trade to that exact same Router contract.

## 9. Security & MEV Exploits in Uniswap V2
Because Uniswap is completely decentralized and operates on a public mempool, user transactions are highly vulnerable to malicious MEV (Maximal Extractable Value) bots if not properly secured by the Router's parameters.

### 1. Exploiting Old Transactions (The `deadline` Parameter)
If a user submits a swap but the Ethereum network becomes congested, their transaction might sit pending in the public mempool for hours. During those hours, the true market price of the asset might shift dramatically. 

If the transaction finally executes hours later using the old, outdated slippage parameters, MEV bots can easily sandwich it and extract massive value. 

To prevent this, every Router function takes a **`deadline`** parameter (a Unix timestamp). The Router enforces a strict `require(block.timestamp <= deadline)` check. If the transaction is delayed in the mempool past the deadline, it safely reverts, preventing the user from executing a trade at an outdated and highly vulnerable price.

### 2. The Danger of Zero Slippage (The `amountMin` Parameter)
It is a catastrophic security failure to ever set `amountOutMin` to `0` (or `amountInMax` to `type(uint).max`) when calling the Router.

If `amountOutMin` is 0, the user is mathematically telling the Router: *"I am willing to accept 0 tokens in return for my deposit."*

MEV bots monitor the mempool for exactly this mistake. If they spot a zero-slippage transaction, they will execute a brutal **Sandwich Attack**:
1. **Front-run:** The bot buys a massive amount of the token, artificially pushing the price in the pool astronomically high.
2. **Execution:** The user's transaction executes at this artificially terrible price. Because their `amountOutMin` was 0, the Router accepts the trade, giving the user practically nothing in return for their massive input.
3. **Back-run:** The bot immediately sells the tokens they bought in step 1 back into the pool at a massive profit, completely draining the value from the user's trade.

To protect against this, frontends always calculate the mathematically expected output, subtract a tiny tolerance (e.g., 0.5%), and pass that strict threshold as the `amountOutMin`.
