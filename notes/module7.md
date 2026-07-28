# Uniswap V3

## 1. How Concentrated Liquidity in Uniswap V3 Works

> **Price Impact:** Any trade on an AMM, no matter how small, shifts the pool's asset reserves and changes the marginal price ($\text{price}' > \text{price}$). The difference between the pool's initial price and the execution price resulting from the trade is called **price impact**. A large trade relative to available liquidity causes high price impact.

> **Capital Efficient Liquidity:** In Uniswap V2, liquidity is spread uniformly across the entire price range $(0, \infty)$, meaning most assets sit idle in unused price ranges. Uniswap V3 allows Liquidity Providers (LPs) to allocate capital to specific price intervals $[p_{min}, p_{max}]$. This "concentrated liquidity" dramatically increases capital efficiency, enabling much higher depth and lower price impact for traders using significantly less total capital.

### Concentrating Liquidity (Piecewise AMM Curve)

Conceptually, concentrated liquidity can be thought of as a piecewise function bounded by price rays extending from the origin (e.g., price ratios $p = \frac{\text{reserve}(y)}{\text{reserve}(x)}$).

By applying `if` conditions at price boundaries, the pool adjusts the constant product $k$ depending on whether the price is within the active range:

$$xy = \begin{cases} 0.1k & \text{if } p < 0.99 \text{ or } p > 1.01 \\ 10k & \text{if } 0.99 \le p \le 1.01 \end{cases}$$

- Within the active price range ($[0.99, 1.01]$), the virtual constant product is multiplied (e.g. $10k$), offering much higher liquidity depth and lower slippage.
- Outside this range, liquidity drops off (e.g. $0.1k$), shifting the effective constant product curve.

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

## 3. Q Number Format

Q numbers are a design pattern to hold fractional numbers in Ethereum.

They are more efficient than standard decimal representation since conversion and scaling can be accomplished with bitshifting.

A Q number is represented as **$Qm.n$**, where $m$ is the number of bits for the integer portion and $n$ is the number of bits for the fractional portion. Each bit after the binary point represents fractional values of $\frac{1}{2}, \frac{1}{4}, \frac{1}{8}, \dots$ etc.

* **Conversion:** An integer can be converted into a Q number by doing a left bitshift by $n$ bits (`a << n`). A Q number can be converted back to an integer by truncating the fraction bits via right-shifting by $n$ bits (`q >> n`).
* **Floating Point Equivalence:** If we divide a Q number by $2^n$ in a language that supports floating points, we get its true decimal value.
* **Ratios:** Given two integers $a$ and $b$ (ensuring $a$ fits within $m$ bits), we compute their ratio as a $Qm.n$ number via `(a << n) / b`. The total number of bits required to hold the fixed-point number is $m + n$.
* **Addition:** Q numbers can be added together "as is" as long as their fractional bits $n$ are aligned.
* **Multiplication:** If we multiply two $Qm.n$ numbers together, we must right-shift the result by $n$ bits (`(A * B) >> n`) so the result maintains $n$ fractional bits.
* **Division:** If we divide two $Qm.n$ numbers, we must first left-shift the numerator by $n$ bits (`(A << n) / B`).

> **Warning:** Both division and multiplication of Q numbers must be carefully written to avoid temporary integer overflow during intermediate steps.

## 4. Square Root Price in Uniswap V3

In Uniswap V2, the protocol tracks token reserves and derives the spot price, $p_x = \frac{y}{x}$, and total liquidity, $L = \sqrt{xy}$, where $x$ and $y$ are the reserves of tokens X and Y.

Uniswap V3, instead, tracks the current price and liquidity, and derives the reserves. This calculation is complex and will be covered in later chapters.

Uniswap V3 actually stores the square root of the price, $\sqrt{P}$, instead of the price itself.

The square root of the price is stored in the field variable `sqrtPriceX96` of the struct `Slot0`.

The relationship between $\sqrt{p}$ and `sqrtPriceX96` is that $\sqrt{p}$ is the actual square root of the price, while `sqrtPriceX96` represents the square root of a token’s price in the **Q64.96** format.

This relationship can be expressed with a simple formula. To convert $\sqrt{p}$ to `sqrtPriceX96`, we use:

$$\text{sqrtPriceX96} = \text{floor}(\sqrt{p} \times 2^{96})$$

To convert back `sqrtPriceX96` to $\sqrt{p}$, we use:

$$\sqrt{p} = \frac{\text{sqrtPriceX96}}{2^{96}}$$

### Why Use Q64.96 to Store the Square Root of the Price?
This is not an easy question to answer, and the protocol team could have chosen a different Q number format. Since they decided to pack the square root of the price together with the current tick and other information in a single 256-bit storage slot (`Slot0`), the space left for the square root of the price was **160 bits** ($64 + 96 = 160$).

## 5. Tick Limits in Uniswap V3

In the previous chapter, we saw that the protocol stores the square root of the token price as fixed-point numbers of type Q64.96. This type of variable has a maximum whole number value of $2^{64}$. Consequently, the highest price it can store is $2^{128}$.

### The Highest Tick Index
Using $p(i) = 2^{128}$ in the formula above, we have that:

$$i = \log_{1.0001}(2^{128}) = 887272$$

The minimum and maximum tick indexes are hardcoded as `MIN_TICK` ($-887272$) and `MAX_TICK` ($887272$) in the Uniswap V3 `TickMath` library.

### Why Use `int24` for Tick Indexes?
The number of bits required to store $887,272$ is $\log_2(887272) \approx 20$. Since we also have negative ticks, we need to store twice that amount of ticks. To hold both the original positive numbers and their negative values, our tick variable needs to support 21 bits.

Since Solidity only supports `int` sizes that are multiples of 8, the smallest `int` size that will hold all the ticks we need is `int24`. Therefore, Uniswap V3 uses `int24` to hold tick indexes.

## 6. Uniswap V3 Factory and the Relationship Between Tick Spacing and Fees

* **Multiple Requirement:** Not all ticks in a pool can be used—only those that are exact multiples of the tick spacing (`tick % tickSpacing == 0`) are allowed.
* **Factory Configuration:** The relationship between tick spacing and fees is set in a mapping (`feeAmountTickSpacing`) inside the Factory contract. Governance can add more tick spacing and fee options using `enableFeeAmount`.
* **High Volatility / Low Liquidity Pairs:** Frequent tick crossing results in higher gas costs, as we will learn when studying swaps. Therefore, pools with higher price volatility and/or lower liquidity should use larger tick spacing to minimize the frequency of allowed ticks being crossed.
* **Low Volatility / High Liquidity Pairs:** On the other hand, for pools with lower price volatility and/or highly liquid pairs, tick spacing can be smaller, as liquidity providers will have a clearer idea of where to concentrate their liquidity.

## 7. Computing the Current Tick Given sqrtPriceX96

To compute the current tick $i$ directly from `sqrtPriceX96`, we use the relationship between price $p$ and `sqrtPriceX96`:

$$\sqrt{p} = \frac{\text{sqrtPriceX96}}{2^{96}} \implies p = \left(\frac{\text{sqrtPriceX96}}{2^{96}}\right)^2$$

Equating this to the tick-to-price formula $p(i) = 1.0001^i$:

$$1.0001^i = \left(\frac{\text{sqrtPriceX96}}{2^{96}}\right)^2$$

Taking the logarithm of both sides and applying log properties ($\log(x^2) = 2\log(x)$), and recalling that the current tick is rounded down to the nearest integer, the accurate formula for tick $i$ is:

$$i = \left\lfloor \frac{2 \log\left(\frac{\text{sqrtPriceX96}}{2^{96}}\right)}{\log(1.0001)} \right\rfloor$$

Conversely, to compute `sqrtPriceX96` given a tick index $i$, we use:

$$\text{sqrtPriceX96} = \sqrt{1.0001^i} \cdot 2^{96}$$

### Implementation in Solidity (`TickMath` Library)
In Solidity, the conversion between tick indexes and `sqrtPriceX96` is handled by the `TickMath` library via two core functions:
* **`getSqrtRatioAtTick(int24 tick)`**: Calculates `sqrtPriceX96` ($\sqrt{1.0001^i} \cdot 2^{96}$) given a tick index $i$.
* **`getTickAtSqrtRatio(uint160 sqrtPriceX96)`**: Calculates the tick index $i$ given a `sqrtPriceX96` value.

> **Security Warning:** It is **not safe** for external smart contracts to directly consume `slot0.sqrtPriceX96` to determine asset prices for valuation, collateral, or liquidation logic. `Slot0` stores the instantaneous spot price, which can be manipulated within a single transaction via flash loans or sandwich attacks. Protocols should instead rely on Uniswap V3 TWAP (Time-Weighted Average Price) oracles.
