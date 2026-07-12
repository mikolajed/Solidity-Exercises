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
