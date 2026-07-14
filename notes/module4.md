# Module 4: DeFi Primitives

## 1. The Staking Algorithm (SushiSwap MasterChef & Synthetix)

The core math behind DeFi staking (popularized by Synthetix and SushiSwap) distributes continuous rewards to thousands of users in $O(1)$ time complexity, completely avoiding Out-of-Gas loop errors.

- **Staking Token**: The asset deposited/locked by the user (e.g., LP tokens).
- **Reward Token**: The yield continuously paid out by the contract (e.g., SUSHI).
- **Reward Debt**: To handle users entering at different times, the contract tracks `rewardDebt`. On deposit, it records the theoretical rewards a user *would* have earned if they had staked since Day 1. On claim, the contract subtracts this `rewardDebt` from their theoretical total since Day 1. The difference equals their actual, correctly-proportioned yield for their specific timeframe.

### Pseudocode: `updatePool()`
The `updatePool()` function is the heartbeat of the algorithm. It is called right before any user interacts with the pool (deposits, withdraws, or claims) to ensure the global `accRewardPerToken` (accumulated reward per token) is perfectly synced with the current block.

```solidity
function updatePool() internal {
    // avoid updating multiple times on one block
    if (block.number <= lastRewardBlock) {
        return;
    }

    // avoid calculating rewards when we would have division by zero
    uint tokenSupplyStaked = lpToken.balanceOf(address(this));
    if (tokenSupplyStaked == 0) {
        lastRewardBlock = block.number;
        return;
    }

    uint rewardToMint = (block.number - lastRewardBlock) * multiplier;
    mint(address(this), rewardToMint);
    accRewardPerToken += rewardToMint / tokenSupplyStaked;
    lastRewardBlock = block.number;
}
```

## 2. Fixed Point Arithmetic in Solidity

The EVM does not natively support floating-point numbers (decimals). To represent fractions and percentages, DeFi protocols use **Fixed Point Arithmetic**—multiplying a value by a large implied denominator so it can be stored as a whole integer.

### Base-10: WADs & Solady
A **WAD** is a number scaled by $10^{18}$ (e.g., $1.0 = 10^{18}$). 
- **Convert to Fixed Point**: Multiply the integer by $10^{18}$.
- **Multiply**: Multiply two WADs, then divide the result by $10^{18}$ to scale it back down.
- **Divide**: Multiply $x$ by $10^{18}$ first, then divide by $y$.

*Note: The **Solady** library provides highly-optimized `mulWad` and `divWad` Yul assembly functions that automatically handle this $10^{18}$ scaling and include built-in overflow/divide-by-zero checks.*

### Base-2: Binary Fixed Point (ABDK & Uniswap V2)
While base-10 is readable, **Binary Fixed Point** (base-2) is vastly more gas-efficient because the EVM can use bitwise operations instead of expensive math opcodes.

**1. ABDK Library (64.64-bit)**
ABDK uses an implied $2^{64}$ denominator.
- **Multiply by Denominator**: Uses a gas-efficient left shift (`x << 64`) to encode standard integers.
- **Divide by Denominator**: Uses a gas-efficient right shift (`(x * y) >> 64`) to scale products back down.

**2. Uniswap V2 (UQ112x112)**
Uniswap V2 uses a 224-bit binary format ($2^{112}$ denominator). Their math library is intentionally minimal because the core protocol only ever needs to *add* fixed point numbers together, or *divide* a fixed point number by a standard integer.

## 3. Flash Loans

Flash loans are loans issued between smart contracts that must be borrowed, utilized, and repaid within the exact same transaction. **ERC-3156** seeks to standardize the interface for getting these flash loans.

### What are Flash Loans used for?
Because they allow users to borrow massive amounts of capital with zero collateral (provided it's repaid instantly), flash loans enable several unique DeFi mechanics:
- **Arbitrage**: Profiting from price differences across different decentralized exchanges.
- **Refinancing Loans**: Swapping out a loan with a high interest rate for one with a lower rate across platforms without needing upfront capital to close the first loan.
- **Exchanging Collateral**: Swapping the underlying collateral of an active loan.
- **Liquidating Borrowers**: Providing the capital needed to liquidate an undercollateralized position and claiming the liquidation bonus.
- **Increasing Yield**: Funneling capital to increase yield for other DeFi applications.
- **Hacking Smart Contracts**: Exploiting logic flaws in protocols (e.g., price oracle manipulation). *Note: The vulnerability is two-sided—a flash lending and flash borrowing contract can also be vulnerable to losing money if not implemented properly.*
- **Building a Leverage Loop**: Looping deposits and borrows in a single transaction to gain massive exposure.

### The Leverage Loop Math
When building a leverage loop using a flash loan, the total amount of assets that can be borrowed in this recursive manner is calculated as:

$$ \text{Max Exposure} = \frac{1}{1 - \text{LTV}} $$

Where **LTV** is the maximum Loan-to-Value ratio the protocol accepts. 

**Example**: If a protocol requires a deposit of $1000 worth of stablecoins to borrow $800 of ETH, the LTV is $800/1000 = 0.8$. 
Thus, using a flash loan leverage loop, a user could gain up to $\frac{1}{1 - 0.8} = 5$ times the exposure to the price of ETH compared to their initial deposit. They could be exposed to $5,000 worth of ETH with only a $1000 deposit.

### The ERC-3156 Interfaces

**1. The Borrower (`IERC3156FlashBorrower`)**
The first aspect of the standard is the interface the borrowing contract needs to implement. The borrower only needs to implement a single function: `onFlashLoan`. 

**2. The Lender (`IERC3156FlashLender`)**
The lender contract must implement the following interface, which defines how much can be borrowed, the fee, and the entry point to actually initiate the loan:

```solidity
import "./IERC3156FlashBorrower.sol";

interface IERC3156FlashLender {
    
    // for a particular token, how much can be flash loaned out
    function maxFlashLoan(address token) external view returns (uint256);

    // for a particular token, how much interest is charged.
    // units are in the token quantity, not interest rate
    function flashFee(address token, uint256 amount) external view returns (uint256);

    // initiate the flash loan for a particular token and amount
    // ANYONE CAN CALL THIS WITH ANY ARGUMENTS
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
}
```

### Security Considerations

> [!WARNING]
> Flash loans introduce massive vectors for exploitation if not implemented carefully on both the lending and borrowing sides.

- **Borrower Access Control**: You must strictly validate that *only* the trusted flash lender contract can call your `onFlashLoan` function. If the lender is immutable, checking `msg.sender` is sufficient; if it is upgradeable, it requires more complex tracking. Without this, malicious actors could arbitrarily trigger flash loan logic on your contract.
- **Input Validation**: The borrower must validate all incoming arguments to ensure they match the expected loan.
- **Reentrancy Locks**: Reentrancy guards are incredibly important on the lender's `flashLoan` function. If locks are missing, a malicious borrower could re-enter the lending contract during the `onFlashLoan` callback to drain funds or manipulate state.
- **Token Recovery Mechanics**: It is crucial that the *lender* is the one actively pulling the tokens (plus the fee) back from the borrower at the end of the transaction. If the lender relies on the borrower to push them back, strict reentrancy locks must be in place to prevent attacks.

## 4. Chainlink Price Feeds

Chainlink provides decentralized price oracles (typically USD-denominated) by aggregating data from multiple off-chain nodes to prevent single-point-of-failure manipulation.

> [!WARNING]
> Always use `latestRoundData()` to read prices. The older `latestAnswer()` function is deprecated.

### On-Chain Architecture
The off-chain prices enter the ecosystem via the `transmit` function. The system relies on 3 core contracts:
1. **Price Feed Contract**: The proxy interface users interact with (where `latestRoundData()` lives).
2. **Aggregator Contract**: The backend engine that receives raw data from nodes via the `transmit` function.
3. **Validator Contract**: (Optional) Validates data bounds before finalization.

### Price Update Frequency
To optimize gas, Chainlink only pushes on-chain price updates under two conditions:
1. **Heartbeat**: A maximum time interval passes (e.g., 1 hour for ETH/USD).
2. **Deviation Threshold**: The off-chain price moves beyond a specific percentage (e.g., 0.5%).

## 5. The Interest Rate Model of Aave V3 and Compound V2

In these protocols, **borrow demand** (the amount of capital borrowed) directly influences interest rates. The ratio of borrowed capital to total available deposits is called **utilization**. 

The interest rate flow operates in this exact order:
`Borrow Demand` $\rightarrow$ `Utilization` $\rightarrow$ `Borrow Rates` $\rightarrow$ `Supply Rates`

### Core Formulas

**1. Utilization**
$$ \text{Utilization} = \frac{\text{Borrowed}}{\text{Total Deposits}} = \frac{\text{Borrowed}}{\text{Borrowed} + \text{Free Deposits}} $$
*Note: If total deposits increase while borrowing stays flat, utilization goes down.*

**2. Supply Interest Rate (With Reserve Factor)**
In reality, lending protocols take a small cut of the interest generated to fund their own treasury and act as an insurance fund. This is called the **Reserve Factor**, and it creates a "spread" between the borrow rate and the supply rate.

$$ \text{Supply Rate} = \text{Borrow Rate} \times \text{Utilization} \times (1 - \text{Reserve Factor}) $$

> **Why multiply by utilization?** Lenders only earn interest on the portion of the pool that is actually borrowed. If the borrow rate is 10%, but only half the pool is loaned out (50% utilization), that 10% interest generated by borrowers must be distributed across *all* depositors. Because half the pool is sitting idle, the lenders' yield is mathematically diluted in half.

*(Note: Compound V3 breaks from this pattern and calculates supply rate solely based on utilization, ignoring the borrow rate).*

### The Self-Balancing Loop
Utilization creates a self-correcting market loop:
- **High Utilization (High Borrow Demand):** Interest rates spike. High rates incentivize lenders to deposit more (increasing supply) and force borrowers to repay expensive debt (decreasing demand), pushing utilization back down.
- **Low Utilization (Excess Liquidity):** Interest rates drop. Low rates disincentivize lenders (decreasing supply) and attract borrowers to take cheap loans (increasing demand), pushing utilization back up.

### Optimal Utilization and the "Kinked" Curve
DeFi applications try to encourage utilization to hover around a specific target percentage (usually between 80% and 95%). This sweet spot is called the **Optimal Utilization**.

To aggressively enforce this target, protocols don't use a straight line for interest rates. Instead, the interest rate curve is typically piecewise linear and **"kinked"**:
- **Before the Kink:** The interest rate rises slowly and steadily as utilization approaches the optimal point.
- **After the Kink:** Once utilization surpasses the optimal point (meaning the protocol is running out of available liquidity), the interest rate spikes aggressively to rapidly force the self-balancing loop to take effect and protect the protocol.

#### Aave's Piecewise Formula
Aave mathematically defines this two-part kinked curve using the following formula for calculating the current borrow rate ($R_{borrow}$):

$$
R_{borrow} = 
\begin{cases} 
R_{intercept} + \frac{U}{U_{optimal}} R_{slope1} & \text{if } U \le U_{optimal} \\
R_{intercept} + R_{slope1} + \frac{U - U_{optimal}}{1 - U_{optimal}} R_{slope2} & \text{if } U > U_{optimal}
\end{cases}
$$

Where:
- $U$ is the current Utilization.
- $U_{optimal}$ is the target optimal utilization point (where the "kink" happens).
- $R_{intercept}$ is the base interest rate when utilization is exactly 0.
- $R_{slope1}$ is the slow, steady growth rate applied *before* the kink.
- $R_{slope2}$ is the aggressive spike rate applied *after* the kink.

*Note: While interest rates are fundamentally a function of utilization, the exact shape of this curve (the specific values for $U_{optimal}$, $R_{intercept}$, $R_{slope1}$, and $R_{slope2}$) is not hardcoded indefinitely—it is set and actively adjusted by protocol **Governance**.*
