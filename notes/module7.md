# Uniswap V3

## 1. How Concentrated Liquidity in Uniswap V3 Works

> **Price Impact:** Any trade on an AMM, no matter how small, shifts the pool's asset reserves and changes the marginal price ($\text{price}' > \text{price}$). The difference between the pool's initial price and the execution price resulting from the trade is called **price impact**. A large trade relative to available liquidity causes high price impact.

> **Capital Efficient Liquidity:** In Uniswap V2, liquidity is spread uniformly across the entire price range $(0, \infty)$, meaning most assets sit idle in unused price ranges. Uniswap V3 allows Liquidity Providers (LPs) to allocate capital to specific price intervals $[p_{min}, p_{max}]$. This "concentrated liquidity" dramatically increases capital efficiency, enabling much higher depth and lower price impact for traders using significantly less total capital.

### Concentrating Liquidity (Piecewise AMM Curve)

Conceptually, concentrated liquidity can be thought of as a piecewise function bounded by price rays extending from the origin (e.g., price ratios $p = \frac{\text{reserve}(y)}{\text{reserve}(x)}$).

By applying `if` conditions at price boundaries, the pool adjusts the constant product $k$ depending on whether the price is within the active range:

$$xy = \begin{cases} 0.1k & \text{if } p < 0.99 \text{ or } p > 1.01 \\ 10k & \text{if } 0.99 \le p \le 1.01 \end{cases}$$

* Within the active price range ($[0.99, 1.01]$), the virtual constant product is multiplied (e.g. $10k$), offering much higher liquidity depth and lower slippage.
* Outside this range, liquidity drops off (e.g. $0.1k$), shifting the effective constant product curve.

![Concentrated Liquidity Piecewise Curve](./img/concentrated_liquidity_curve.png)

### How Uniswap V3 Implements Concentrated Liquidity

To make things flexible in letting the LPs decide the ideal boundaries and quantity for where to place liquidity, Uniswap V3 doesn’t use a scaling factor at all. Within certain price boundaries, $k$ will be the liquidity the LPs provide there. That is, liquidity providers can choose from a variety of price regions where they can provide liquidity.

Even though the curves appear to be discontinuous, the price (represented with the orange ray) can transition smoothly between each “mini Uniswap V2 curve.” Each of the “sub curves” are of the form $xy = k$, but $k$ is different for each sub curve.

To keep accounting simple, LPs cannot provide liquidity at arbitrary price boundaries, but at predefined prices called ticks.

![Ticks and Price Rays Visualization](./img/ticks_and_price_rays.png)

![Uniswap V3 Piecewise Liquidity Curves](./img/piecewise_uniswap_v3_curves.png)

### Uniswap V3 Invariant

Uniswap V3 can be conceptualized as using the following invariant:

$$xy = \begin{cases} k_1 & \text{if } \text{tick}_0 \le p < \text{tick}_1 \\ k_2 & \text{if } \text{tick}_1 \le p < \text{tick}_2 \\ k_3 & \text{if } \text{tick}_2 \le p < \text{tick}_3 \\ \vdots & \\ k_n & \text{if } \text{tick}_{n-1} \le p < \text{tick}_n \end{cases}$$

In practice, it is not gas-efficient to check the price against so many potential cases like we do in the formula above. Similarly, keeping track of so many $k$ values is expensive.

## 2. Introducing Ticks in Uniswap V3

In Uniswap V3, prices always refer to the price of token X in terms of token Y. Thus, anytime we write $p$, it refers to the price of token X, given by $p = p_x = \frac{y}{x}$.

### The Tick to Price Formula

We said that ticks are pre-defined prices, but how are these prices defined? They are defined by the following formula:

$$p(i) = 1.0001^i$$

The allowed tick indexes range from $-887,272$ to $887,272$.

### Distinction: Price vs. Ticks
It is important to distinguish between the pool's current active price and the tick prices:
* **Ticks** are specific, discrete price points along the price curve defined by $1.0001^i$. They serve as boundaries where LPs can set their position limits.
* **The current pool price ($p$)** is a continuous value that transitions smoothly between these ticks as swaps occur. The pool's actual trading price can be any arbitrary number (e.g., a price between two ticks), whereas tick prices are restricted to the fixed values calculated by the formula above.

### Why 1.0001?
According to the Uniswap V3 Whitepaper, the base value $1.0001$ was chosen because:
> "This has the desirable property of each tick being a 0.01% (1 basis point) price movement away from each of its neighboring ticks."

### Visualizing Tick Spaces (Ray vs. Linear Representations)
By using tick indexes, Uniswap V3 maps a non-linear price space into a linear integer index space. LPs can place liquidity at discrete tick intervals, creating a stepped distribution of liquidity depth ($L$) across ticks:

![Tick Representation Comparison](./img/tick_representations_comparison.png)

### The Current Tick
Uniswap V3 keeps track of the "active tick", "current tick", or sometimes just "tick". The **current tick** is defined as the current price rounded down to the nearest tick.

In code, the protocol stores the current tick (along with `sqrtPriceX96`) in storage slot 0 inside a struct named `Slot0`.
