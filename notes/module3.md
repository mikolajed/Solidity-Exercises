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
