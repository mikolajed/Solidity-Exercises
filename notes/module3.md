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
