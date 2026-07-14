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

## 2. The Architecture of Uniswap V2
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
