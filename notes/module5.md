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
