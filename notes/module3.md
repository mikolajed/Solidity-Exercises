# Module 3: Intermediate Topics

## 1. Checking if a Caller is a Smart Contract

It is often necessary to determine if the address calling your smart contract is an Externally Owned Account (EOA) or another smart contract. There are three primary ways to attempt this, each with distinct trade-offs and vulnerabilities:

### 1. The `tx.origin` Check

```solidity
require(tx.origin == msg.sender, "Caller is a smart contract");
```

- **How it works**: `tx.origin` always points to the EOA that initiated the entire transaction. If `tx.origin` is exactly the same as `msg.sender`, it means no intermediate smart contracts were called before reaching your contract.
- **The Issue**: This breaks compatibility with **Account Abstraction (ERC-4337)**. In ERC-4337, users operate via Smart Contract Wallets instead of traditional EOAs. Blocking smart contracts using `tx.origin` prevents users with smart wallets from interacting with your protocol.

### 2. The `code.length` Check

```solidity
require(msg.sender.code.length == 0, "Caller is a smart contract");
```

- **How it works**: Smart contracts have bytecode deployed on-chain, whereas EOAs have a code length of 0.
- **The Issue**: A smart contract's `code.length` is actually `0` _while it is still being constructed_. A malicious actor can bypass this check entirely by putting their attack logic inside their contract's `constructor()`.

### 3. The `codehash` Check

```solidity
bytes32 accountHash = msg.sender.codehash;
// Check if the account has no code, or if the account is completely empty/non-existent
require(accountHash == keccak256("") || accountHash == bytes32(0), "Caller is a smart contract");
```

- **How it works**: Instead of checking the length, you check the hash of the code stored at the address.
- **The Details**: You must check two different conditions:
  1. `bytes32(0)`: This is returned if the address does not exist on-chain yet (it has no state, balance, or nonce).
  2. `keccak256("")`: This is returned if the address exists (e.g., an EOA with a balance) but holds no smart contract code.
- **The Issue**: Just like `code.length`, this method can still be bypassed if the calling contract executes the attack from within its `constructor()`.

## 2. Function Selectors & Encoding

- **Function Selector**: The first 4 bytes of transaction call data that dictate which function to execute. It is derived from the first 4 bytes of the hash of the function signature (e.g., `bytes4(keccak256("myFunction(uint256)"))`). Note that a function signature is strictly the function's name and its parameter types **without any spaces, argument names, or data location keywords** (such as `memory` or `calldata`). Importantly, **internal and private functions do not have selectors**, as they are only accessed via jumps in the internal bytecode rather than through external call data. Finally, keep in mind that **function selectors are a Solidity application-level abstraction**, not an EVM-level feature; the EVM simply executes raw bytecode, and it is the Solidity compiler that injects the routing logic to read those first 4 bytes.
  - **Selector Collisions**: Because the selector is only 4 bytes, hash collisions are possible (though rare). If two functions in the same contract hash to the same 4-byte selector, the Solidity compiler will refuse to compile the contract. For example, `collate_propagate_storage(bytes16)` and `burn(uint256)` both evaluate to the exact same selector (`0x42966c68`).
  - **Useful Tools**: You can look up the human-readable function signatures for a known selector using databases like [4byte.directory](https://www.4byte.directory/), or quickly calculate selectors using tools like [evm-function-selector.click](https://evm-function-selector.click/).
- **`msg.sig`**: A global variable that returns the 4-byte selector of the _original_ external function called in the transaction. If `Function A` internally calls `Function B` in the same contract, `msg.sig` inside `Function B` will still equal the selector for `Function A`. **Note:** If the transaction triggered the `fallback` or `receive` function (e.g., if no function selector matched or call data was empty), `msg.sig` will simply evaluate to `bytes4(0)` (all zeroes).
- **`abi.encodePacked(...)`**: Tightly packs data into bytes without the standard 32-byte padding. It is highly gas-efficient for hashing (`keccak256(abi.encodePacked(a, b))`). **Warning:** Passing multiple dynamic types (like strings or arrays) consecutively into `encodePacked` causes hash collisions (e.g., `encodePacked("a", "bc")` is identical to `encodePacked("ab", "c")`). Use `abi.encode()` instead if dynamic types touch each other.

## 3. ERC721 (Non-Fungible Tokens)

- **Under the Hood**: An NFT is fundamentally just a number sitting in a `mapping(uint256 => address)` inside a smart contract, recording which address owns that specific number.
- **Unique Identity**: Globally, an NFT is uniquely identified by exactly three variables:
  1. **Chain ID** (e.g., Ethereum vs. Base)
  2. **Contract Address**
  3. **Token ID** (usually `uint256`)
- **Minting is Custom**: The `mint` function is **not** part of the official ERC721 specification. The standard only dictates how existing tokens are tracked and transferred. It is entirely up to the developer to define exactly how, when, and by whom new NFTs are minted into existence and burned.

### Core ERC721 Functions & Concepts

- **`ownerOf` (Ownership Mapping)**: Returns the specific address that owns a given `tokenId`.
- **`mint` / `_mint` (Token Creation)**: The mechanism to bring a new token into existence and assign its first owner.
- **`transferFrom` (Transferring Ownership)**: Moves a token from one address to another. The caller must be the owner or an approved party.
- **`balanceOf` (Ownership Count)**: Returns the total number of NFTs held by a specific address.
- **`setApprovalForAll` & `isApprovedForAll` (Delegating Transfer Rights)**: Allows an owner to grant a third party (like a marketplace or protocol) unrestricted permission to transfer _all_ of their tokens within the contract.
- **`approve` & `getApproved` (Single NFT Approval Mechanism)**: Allows an owner to grant a third party permission to transfer _one specific_ token.
- **`safeTransferFrom` & `_safeMint` (Secure Transfer Functions)**: These functions actively check if the receiving address is a smart contract. If it is, they require the receiver to implement `onERC721Received` to confirm it knows how to handle NFTs. If it doesn't, the transaction reverts to prevent the NFT from being permanently stuck.
- **`burn` / `_burn` (NFT Destruction)**: The mechanism to permanently destroy a token and remove it from circulation.

### Library Choices

- **Solady ERC721**: While OpenZeppelin is the industry standard for security and readability, if gas optimization is a primary concern, consider using the [Solady](https://github.com/Vectorized/solady) library's `ERC721` implementation. It is heavily optimized using inline assembly and offers considerable gas savings for minting, transferring, and tracking tokens.

## 4. ERC1155 (Multi-Token Standard)

- **Multiple Tokens, One Contract**: ERC1155 is a standard that allows a single smart contract to manage multiple different token types simultaneously (fungible, non-fungible, or semi-fungible).
- **Token IDs**: Because the contract manages multiple distinct tokens, every core function (like transferring or checking balances) must explicitly specify the `id` of the token you are interacting with, in addition to the `amount`.
  - **ID Structure**: The standard only dictates that IDs must be unique; exactly how they are computed is entirely up to the contract developer. A common pattern is to split the `uint256` token ID in half: the top 128 bits represent the specific _collection_ or token type, and the bottom 128 bits represent the individual _item_ (like the index of an NFT within that collection).
- **ERC1155D**: A heavily gas-optimized, backwards-compatible variant of the standard. It achieves significant gas savings but is strictly restricted to supporting only a _single_ collection of NFTs per contract (sacrificing the multi-collection capability for maximum efficiency).

### Core ERC1155 Functions & Concepts

- **`balanceOf`**: Returns the balance of a specific `id` for a specific address.
- **`balanceOfBatch`**: Returns the balances of multiple `id`s for multiple addresses in a single, gas-efficient call.
- **`setApprovalForAll` / `isApprovedForAll`**: Grants or checks permission for an operator to manage _all_ tokens (across all IDs) owned by the caller. (Note: ERC1155 does not have a single-token `approve` function).
- **`safeTransferFrom`**: Securely transfers a specific `amount` of a specific `id`. **ERC1155 ONLY supports safe transfers**; if the receiving address is a smart contract, it _must_ implement the `onERC1155Received` hook or the transaction reverts.
- **`safeBatchTransferFrom`**: Securely transfers multiple `id`s and `amount`s in a single transaction (requires the receiving contract to implement `onERC1155BatchReceived`).
- **No Token Enumeration**: The standard does not support a mechanism to list all existing token IDs on-chain. To discover all existing IDs within an ERC1155 contract, you must parse the contract's emitted transfer logs off-chain.
- **Metadata URI**: The standard does not require ERC1155 tokens to have URI metadata associated with them. However, if an implementation does define a token's URI, it _must_ point to a JSON file that conforms exactly to the official "ERC1155 Metadata URI JSON Schema":
  ```json
  {
    "title": "Token Metadata",
    "type": "object",
    "properties": {
      "name": {
        "type": "string",
        "description": "Identifies the asset to which this token represents"
      },
      "decimals": {
        "type": "integer",
        "description": "The number of decimal places that the token amount should display - e.g. 18, means to divide the token amount by 1000000000000000000 to get its user representation."
      },
      "description": {
        "type": "string",
        "description": "Describes the asset to which this token represents"
      },
      "image": {
        "type": "string",
        "description": "A URI pointing to a resource with mime type image/* representing the asset to which this token represents. Consider making any images at a width between 320 and 1080 pixels and aspect ratio between 1.91:1 and 4:5 inclusive."
      },
      "properties": {
        "type": "object",
        "description": "Arbitrary properties. Values may be strings, numbers, object or arrays."
      }
    }
  }
  ```
  Additionally, the standard supports a `localization` property to serve metadata in multiple languages:
  ```json
  {
    "title": "Token Metadata",
    "type": "object",
    "properties": {
      "...": "...",
      "localization": {
        "type": "object",
        "required": ["uri", "default", "locales"],
        "properties": {
          "uri": {
            "type": "string",
            "description": "The URI pattern to fetch localized data from. This URI should contain the substring `{locale}` which will be replaced with the appropriate locale value before sending the request."
          },
          "default": {
            "type": "string",
            "description": "The locale of the default data within the base JSON"
          },
          "locales": {
            "type": "array",
            "description": "The list of locales for which data is available. These locales should conform to those defined in the Unicode Common Locale Data Repository (http://cldr.unicode.org/)."
          }
        }
      }
    }
  }
  ```

## 5. Working with Strings (OpenZeppelin)

Solidity does not have robust native string manipulation. To convert integers (like Token IDs) into strings—which is almost always required when constructing a `tokenURI` or `uri` to return metadata—you should use OpenZeppelin's `Strings` library.

- **`Strings.toString(uint256 value)`**: Converts a `uint256` to its ASCII string decimal representation.
- **`Strings.toHexString(uint256 value, uint256 length)`**: Converts a `uint256` to its ASCII string hexadecimal representation. The `length` parameter specifies the number of **bytes** (not characters) to represent. For example, `Strings.toHexString(id, 32)` converts the `id` into a 64-character hex string (since 32 bytes = 64 hex characters) prefixed with `0x`. This is particularly useful when dealing with ERC1155 IDs where the 256-bit integer is split into halves.

## 6. ERC4626 (Tokenized Vault Standard)

- **Extension of ERC20**: The ERC4626 standard extends the ERC20 contract. During construction, an ERC4626 vault takes the address of another specific ERC20 token as an argument. This is the underlying "asset" token that users will deposit into the vault.
- **Inherits ERC20 Functionality**: Because it extends ERC20, the ERC4626 vault itself acts as a token (representing your shares in the vault). Therefore, it natively supports all standard ERC20 functions and events, including `balanceOf`, `transfer`, `transferFrom`, `approve`, and `allowance`.

### Entering the Vault

- **`deposit(uint256 assets)`**: You specify how many underlying **assets** you want to put in, and the function calculates how many **shares** to mint and send back to you.
  - **`previewDeposit(uint256 assets)`**: A view function that simulates a deposit. It returns the exact amount of shares you _would_ receive for the given assets under current market conditions (accounting for any fees/slippage).
  - **`convertToShares(uint256 assets)`**: An "ideal" view function that simply calculates the base conversion rate from assets to shares. Unlike `previewDeposit`, it typically does _not_ account for fees or slippage.
- **`mint(uint256 shares)`**: You specify exactly how many **shares** you want to receive, and the function calculates how much of the underlying **asset** must be transferred from you to pay for them.
  - **`previewMint(uint256 shares)`**: A view function that simulates a mint. It returns the exact amount of assets you _would_ need to supply to receive the given amount of shares.

### Exiting the Vault

- **`withdraw(uint256 assets)`**: You specify how many underlying **assets** you want to pull out, and the function calculates and burns the necessary number of **shares** from you.
  - **`previewWithdraw(uint256 assets)`**: A view function that simulates a withdrawal. It returns the exact amount of shares that _would_ be burned under current market conditions.
- **`redeem(uint256 shares)`**: You specify exactly how many **shares** you want to burn, and the function calculates how much of the underlying **asset** to send back to you.
  - **`previewRedeem(uint256 shares)`**: A view function that simulates a redeem. It returns the exact amount of assets you _would_ receive.
  - **`convertToAssets(uint256 shares)`**: An "ideal" view function that simply calculates the base conversion rate from shares to assets. Unlike `previewRedeem`, it typically does _not_ account for fees or slippage.

### Vault Limits

Because Vaults often enforce caps or dynamic limits on how much liquidity can enter or leave at a time, the standard includes four view functions to check the absolute maximums available to a specific user:

- **`maxDeposit(address receiver)`**: The maximum amount of **assets** that can be deposited for the `receiver` in a single call.
- **`maxMint(address receiver)`**: The maximum amount of **shares** that can be minted for the `receiver` in a single call.
- **`maxWithdraw(address owner)`**: The maximum amount of **assets** that can be withdrawn from the `owner`'s balance in a single call.
- **`maxRedeem(address owner)`**: The maximum amount of **shares** that can be redeemed from the `owner`'s balance in a single call.

### Slippage Protection

Whenever you "swap" tokens (such as exchanging assets for vault shares, or vice versa), you are vulnerable to **slippage**—the risk that the conversion rate changes unfavorably before your transaction is mined. A standard defense against this is to calculate the minimum expected return off-chain and pass it into your function as a tolerance parameter (e.g., `minAmountOut`). The contract will check the final output, and if it falls below your minimum tolerance, it intentionally reverts the entire transaction.

### The Inflation Attack (Donation Attack)

A classic vulnerability in early or naive ERC4626 vault implementations is the **Inflation Attack**.

- **The Setup**: An attacker acts as the very first depositor in an empty vault, minting exactly 1 share by depositing 1 wei of the underlying asset.
- **The Attack**: The attacker then directly transfers (donates) a massive amount of the underlying asset to the vault contract _without_ using the deposit function (meaning no new shares are minted).
- **The Result**: Because the exchange rate is dynamically calculated as `totalAssets() / totalShares()`, this direct donation artificially inflates the value of the attacker's single share to a massive number. When a legitimate user subsequently tries to deposit normal amounts of assets, the heavily inflated ratio often causes the calculation of their shares to round down to zero due to Solidity's integer division. The attacker can then redeem their single share to steal the new user's assets.
- **The Mitigations**: There are three primary defenses against this attack:
  1. **Slippage Tolerance**: Revert the transaction if the shares received fall below the user's expected `minAmountOut` (as described in Slippage Protection).
  2. **Initial "Dead" Deposit**: The deployer should deposit a sufficiently large amount of assets into the pool upon creation and permanently lock or burn those initial shares. This makes executing the inflation attack prohibitively expensive.
  3. **Virtual Liquidity**: Modern implementations (like OpenZeppelin v4.9+) natively mitigate this by hardcoding "virtual shares" and "virtual assets" as offsets in the pricing formula, making the pool behave as if it had been deployed with enough assets.

### How Virtual Liquidity Works

Modern implementations (like OpenZeppelin) defeat the Inflation Attack natively by anchoring the exchange rate formula with **Virtual Liquidity**:

- **The Formula**: Instead of `assets * (totalShares / totalAssets)`, the math is calculated as `assets * ((totalShares + virtualShares) / (totalAssets + virtualAssets))`.
- **The Defense**: By injecting fake "virtual" assets and shares into the formula, the vault behaves as if it is never empty. If an attacker tries to donate massive amounts of assets to skew the ratio, they must overcome the massive virtual denominator, making the attack economically unviable.
- **Why it's safe (Rounding Rules)**: Virtual liquidity never causes the contract to "overpay" users. The ERC4626 standard dictates that all conversion math must **strictly round against the user** (e.g., when depositing, shares round DOWN; when redeeming, assets round DOWN). Any microscopic precision loss from the virtual offsets is safely absorbed by the vault as "dust".

## 7. ERC721 Enumerable

The ERC721 Enumerable extension enables on-chain discovery of tokens by explicitly tracking two things:

1. **All the token IDs in existence**: It accomplishes this by using the internal data structures `_allTokens` and `_allTokensIndex`.
2. **All the token IDs a specific address owns**: It accomplishes this by using the internal data structures `_ownedTokens` and `_ownedTokensIndex`.

### Core Functions

By maintaining these internal structures, the extension exposes three primary view functions to the public:

- **`totalSupply()`**: Returns the total amount of valid NFTs currently tracked by the contract.
- **`tokenByIndex(uint256 index)`**: Returns the token ID at a given global index. You can iterate from `0` to `totalSupply() - 1` to discover every single NFT currently in existence within the contract.
- **`tokenOfOwnerByIndex(address owner, uint256 index)`**: Returns the token ID owned by `owner` at a given index. You can iterate from `0` to `balanceOf(owner) - 1` to discover every single NFT owned by that specific address.

### Under the Hood: Swap-and-Pop

When a token is transferred or burned, it must be removed from the previous owner's enumeration list. Because deleting an element from the middle of an array normally requires shifting all subsequent elements down (which is extremely gas inefficient), the internal `_removeTokenFromOwnerEnumeration()` function uses a classic **swap-and-pop** technique:

1. It finds the exact index of the token to be removed.
2. It takes the **last** token in the user's `_ownedTokens` array and copies (swaps) it into the index of the token being removed.
3. It then simply deletes the very last slot of the array (popping it).
   This keeps the array perfectly packed without gaps, and ensures the removal always executes in $O(1)$ time complexity regardless of how many tokens the user owns.

### Internal State Hooks

To keep the enumeration arrays perfectly in sync with actual token ownership, the extension relies on internal lifecycle functions:

- **`_update(address to, uint256 tokenId, address auth)`**: In OpenZeppelin v5, this is the master internal hook that runs on every transfer, mint, and burn. The Enumerable extension overrides this `_update` function to automatically manage the enumeration arrays before passing control back to the core ERC721 transfer logic.
- **`_addTokenToOwnerEnumeration(address to, uint256 tokenId)`**: Called during minting or transferring to simply append the new token to the end of the `to` address's `_ownedTokens` array and save its index.
- **`_addTokenToAllTokensEnumeration(uint256 tokenId)`**: Called exclusively during minting to append the newly created token to the global `_allTokens` array and save its index.
- **`_removeTokenFromAllTokensEnumeration(uint256 tokenId)`**: Called exclusively during burning. Just like the owner removal function, this utilizes the **swap-and-pop** technique on the global `_allTokens` array to maintain strict $O(1)$ efficiency when permanently destroying a token.

## 8. ERC1363 (Payable Token Standard)

- **The Problem**: Standard ERC20 `transfer()` is "deaf"—the receiving contract isn't notified, forcing a costly, 2-step `approve` + `transferFrom` process (which doubles gas and introduces "infinite approval" security risks).
- **The Solution**: ERC1363 makes tokens act like native ETH. It introduces **`transferAndCall`**, which transfers tokens and immediately notifies the receiving contract in a single transaction by triggering a standardized callback function (a **hook**).
- **Security Checks (`IERC1363Receiver` & `IERC1363Spender`)**: Contracts must implement the `onTransferReceived` hook to receive transfers, or the `onApprovalReceived` hook to receive approvals. Inside these hooks, you must **always** `require(msg.sender == tokenAddress)`. Otherwise, anyone can call them directly to fake deposits or approvals.
- **Backwards Compatibility**: ERC1363 is fully backwards compatible with ERC20. It simply adds 6 new functions on top of the standard (two versions of each: with and without data payloads):
  - **`transferAndCall`**
  - **`transferFromAndCall`**
  - **`approveAndCall`** (Triggers `onApprovalReceived` on the spender so they can react instantly to an allowance).
- **Historical Context (Why not ERC777 or ERC223?)**: ERC1363 wasn't the first attempt at adding transfer hooks to tokens.
  - **ERC223 (May 2017)** injected the hook directly into the standard `transfer` function. This broke backwards compatibility because older smart contracts without the hook could no longer receive the token.
  - **ERC777 (Nov 2017)** used a global registry to trigger hooks on standard transfers. Because older DeFi protocols didn't expect a standard ERC20 transfer to execute an external contract call, it introduced catastrophic **reentrancy vulnerabilities** (infamously exploited in Uniswap V1).
    ERC1363 succeeded because it isolates the hooks into brand new functions (`transferAndCall`), leaving the standard `transfer` function completely safe and untouched.

## 9. Understanding the `uint256` Max Value

Solidity and the EVM operate entirely on 256-bit words. Understanding the sheer scale and mechanics of these data types is critical:

- **Two's Complement**: The EVM uses Two's Complement to represent signed integers (`int`). You can safely retrieve their absolute boundaries natively using `type(int256).max` and `type(int256).min`.
- **Retrieving the Max Value**:
  - The standard way to get the maximum value of a `uint256` is `type(uint256).max`.
  - A mathematically equivalent approach is doing a bitwise NOT on zero: **`~uint256(0)`**. This perfectly flips all 256 bits to `1`.
  - _(Note: Using `uint256(-1)` used to be a popular hack to hit the max value via underflow, but this **doesn't work anymore** in Solidity 0.8.0+ due to built-in overflow/underflow protection)._
- **The Astronomical Scale**: A `uint256` can hold numbers up to roughly $1.15 \times 10^{77}$. To put that sheer size into perspective: just 1,000 `uint256` variables could perfectly enumerate every single atom in the known universe.
- **The Collision Corollary**: Because the numerical search space is so incomprehensibly massive, two randomly chosen `uint256` values (which is equivalent to the output of a `keccak256` hash) will, for all practical purposes, **never have a collision**.

## 10. Solidity Signed Integers

Solidity and the EVM use **Two's Complement** representation for signed integers (`int`). Because the highest-order bit dictates the sign (0 for positive, 1 for negative), the bitwise layouts look like this (using `int8` as an example):

- `int8(0)` == `0000 0000`
- `type(int8).max` == `0111 1111`
- `type(int8).min` == `1000 0000`

### Dedicated Signed Opcodes

Because negative numbers start with a `1` at the most significant bit, they technically "appear" larger than positive numbers if evaluated as raw binary. Therefore, standard comparison operators and math functions break. Multiplication, division, modulo, right-shifting, and casting to larger sizes all require entirely different logic under the hood.

To solve this, the EVM has specific opcodes exclusively for signed arithmetic:

- **`slt` and `sgt`**: Signed Less Than / Signed Greater Than. They know that `1111...1111` is actually `-1`, not the max value.
- **`sdiv` and `smod`**: Signed Division and Signed Modulo.
- **`sar`**: Signed Arithmetic Shift Right. Unlike standard `shr` (which pads with zeros), `sar` preserves the sign bit, padding with `1`s if the number is negative.
- **`signextend`**: Essential when casting a smaller signed integer to a larger one (e.g., `int8` to `int256`), ensuring the sign bit is correctly stretched across the new empty space.

## 11. Staticcall (EIP-214)

A `staticcall` is exactly like a regular `call`, except **it immediately reverts if any state change occurs**. It enforces strictly read-only interactions.

- **Meta Arguments (Gas Forwarding)**: You can forward a specific amount of gas, subject to the **EIP-150 63/64 rule**:
  ```solidity
  (bool success, bytes memory data) = target.staticcall{gas: amount}(abiEncodedArgs);
  ```
- **Precompiled Contracts**: `staticcall` is the standard and appropriate way to interact with Ethereum's precompiled contracts (located at addresses `0x01` through `0x09`, such as `ecrecover` or `sha256`).
- **Vulnerability 1: Gas Griefing (DoS)**: If you `staticcall` an untrusted contract (e.g., calling `balanceOf`), it can trap you in an infinite loop and burn all forwarded gas. Under EIP-150, your parent contract survives but is only left with 1/64th of its original gas—often causing your entire transaction to run out of gas and fail anyway.
- **Vulnerability 2: Read-Only Reentrancy**: While `staticcall` prevents state manipulation, it is highly vulnerable to **oracle manipulation**. If an attacker uses a flashloan to temporarily distort a target contract's state, your `staticcall` will retrieve those falsified numbers, tricking your contract into executing flawed logic based on fake data.

## 12. Ownable

The standard OpenZeppelin `Ownable` contract provides basic access control, but its core `transferOwnership(newOwner)` function has a massive, well-known shortcoming: **it executes in a single step**.

If the current owner accidentally mistypes the `newOwner` address, or pastes a non-existent or inaccessible address, the ownership of the contract is instantly and permanently lost. The transaction cannot be undone.

### The Solution: `Ownable2Step`

Because of this risk, **`Ownable2Step` is significantly safer than `Ownable`** and is widely considered the modern best practice for access control.

`Ownable2Step` completely eliminates the typo risk by requiring a two-transaction "handshake":

1. **Step 1 (`transferOwnership`)**: The current owner proposes a new address to take over. The contract saves this as the `_pendingOwner`. The original owner still retains full control.
2. **Step 2 (`acceptOwnership`)**: The pending owner must actively call this function from their own wallet to finalize the transfer.

If the original owner made a typo, the mistyped address will never be able to call `acceptOwnership()`. The original owner retains control and can simply restart the process with the correct address.

### Renouncing Ownership

The `Ownable` contract also includes a `renounceOwnership()` function. This permanently sets the `owner` to `address(0)`. Once called, **no one** can ever call `onlyOwner` functions again. It is a one-way, irreversible action typically used to prove to a community that a contract is now fully decentralized and can no longer be maliciously manipulated by its original developer.

## 13. Testing Internal Functions in Solidity

Because test scripts cannot call `internal` functions directly, you must use a specific methodology:

- **The Wrapper Contract**: Create a child contract that inherits from the contract you want to test. Write an `external` function inside the child that simply wraps and calls the parent's `internal` function. Deploy the child in your tests and call the wrapper.
- **Why not just make it `public`?**: Never change an `internal` function to `public` just for testing. It adds raw bytecode (increasing deployment cost) and bloats the function selector table (increasing the execution gas cost of *every other public function* because the EVM has to search through a larger table to route transactions).
- **Testing `private` functions**: `private` functions are invisible to child contracts, so the wrapper trick fails. The solution? Just change `private` to `internal`. Because the distinction between private/internal is purely a compiler safeguard (and completely disappears in EVM bytecode), making this change has **absolutely zero impact on gas cost or contract size**.

## 14. Gasleft

`gasleft()` is a globally available, built-in Solidity function used to check the exact amount of gas remaining during execution. *(Note: It replaces the deprecated `msg.gas` syntax).*

### Practical Uses & Real-World Applications

- **Measuring Code Consumption (Chainlink VRF)**: Capture gas before and after logic to calculate exact costs. `Chainlink VRFCoordinatorV2` uses this exact pattern to accurately bill users for random number fulfillment callbacks.
  ```solidity
  uint256 startGas = gasleft();
  // ... execute complex logic ...
  uint256 gasUsed = startGas - gasleft();
  ```
- **Guarding Against Griefing (OZ Minimal Forwarder)**: In meta-transactions, a malicious relayer might provide less gas than the user requested, causing the transaction to fail mid-execution (SWC-126). OpenZeppelin's `Minimal Forwarder` uses `gasleft()` to ensure the relayer provided sufficient gas *before* executing the payload.
- **Preventing Out-of-Gas Reverts (Chainlink EthBalance Monitor)**: When looping through large arrays, contracts can check `gasleft()`. If gas drops too low, the contract can gracefully break the loop and save state, rather than reverting the entire transaction.
- **Forwarding Gas (OZ Proxies)**: Proxies use `gasleft()` inside Yul assembly to capture and forcefully forward all remaining gas directly to the underlying logic implementation.
