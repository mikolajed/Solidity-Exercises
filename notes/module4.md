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
