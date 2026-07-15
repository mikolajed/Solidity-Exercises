# Delegatecalls and Proxies

## 1. Understanding ABI Encoding for Function Calls

**ABI (Application Binary Interface) encoding** is the strict, low-level data format used to interact with the EVM. 

Whenever an EOA (a normal user wallet) makes a function call to a smart contract, or whenever a smart contract makes an external call to *another* smart contract, the function name and its arguments must be translated into raw hexadecimal byte arrays. This translation process is ABI encoding.

At the hardware level, the EVM has no concept of "functions," "strings," or "arrays"—it only understands raw bytes. ABI encoding is the universal standard that dictates exactly how complex data structures and function signatures are packed into a raw byte payload so the EVM can parse and execute them.

### Anatomy of an ABI Encoded Call
When a function is called, the resulting ABI-encoded byte array is simply the concatenation of two things:
1. **The Function Selector** (4 bytes)
2. **The Encoded Arguments** (if the function takes any)

In Solidity, you can manually construct these byte payloads to execute low-level calls to other contracts using `abi.encodeWithSignature`:

```solidity
// Calling foo(uint256) and passing 5 as the argument
(bool success, ) = otherContractAddr.call(abi.encodeWithSignature("foo(uint256)", 5));
```

### The Function Selector
The function selector is how the EVM identifies *which* function inside a contract you are trying to execute. It is simply the **first 4 bytes of the Keccak-256 hash of the function signature string**.

You can compute this directly in Solidity:
```solidity
function getSelector() public pure returns (bytes4) {
    // The hash of "transfer(address,uint256)" results in 0xa9059cbb...
    return bytes4(keccak256("transfer(address,uint256)")); 
}
```

#### Signature Corner Cases
When writing a function signature as a string (like `"transfer(address,uint256)"`), there are extremely strict formatting rules you must follow. If you make a mistake, the resulting hash will be completely wrong and the EVM will reject the call:
- **No spaces:** `"foo(uint256)"`, never `"foo(uint256 )"` or `"foo(uint256, address)"`.
- **Use canonical types:** You must use the full type name (e.g., use `uint256`, never `uint`).
- **Structs:** Treated as tuples (e.g., `(uint256,address)`).
- **Addresses & Contracts:** `payable` addresses, interface types, and contract names must all be written simply as `address`.
- **Enums:** Treated as `uint8`.
- **User Defined Types:** Treated as their underlying primitive type.
- **Modifiers:** Location keywords like `memory` and `calldata` are ignored entirely.

#### Note: Function Selector Collisions
Because the function selector is only 4 bytes long (yielding about 4.29 billion possible combinations), mathematical collisions are inevitable. If two entirely different function signatures happen to produce the exact same 4-byte hash:
- **Within a Single Contract:** The Solidity compiler will detect the duplicate hashes and throw a fatal `DeclarationError: Function signature hash collision`. You must rename one of the functions or change its arguments to randomize the hash and resolve the collision.
- **Across Multiple Contracts (Proxies):** The compiler cannot save you if a collision occurs between two separately compiled contracts (like a Proxy and its Logic contract). This leads to the infamous "Function Selector Clash" vulnerability, which must be solved using strict routing architectures (like the Transparent Proxy Pattern).

### Calldata & 32-Byte Padding
When a transaction is sent, the resulting ABI-encoded byte payload is not stored permanently in the contract's storage. Instead, it lives in a special, highly efficient EVM memory space called **`calldata`**. 

Because `calldata` represents the exact input bytes sent by the transaction sender, it is strictly **read-only**—it cannot be modified during execution.

When packing arguments into `calldata`, the EVM universally operates on **32-byte words**. Therefore, every single encoded argument is forced into a 32-byte slot. If an argument (like a `uint8` or an `address`) does not naturally take up 32 bytes, it is automatically padded with zeros to fill the remaining space.

### Fixed vs. Dynamic Types
Understanding exactly how the EVM pads and encodes these 32-byte words requires dividing Solidity's data types into two strict categories: fixed and dynamic.

#### Fixed-Size Types
These types have a known, predictable size at compile time. They are encoded perfectly sequentially in `calldata`.
- `bool`
- `uint<M>` and `int<M>` (e.g., `uint256`, `int8`)
- `bytes<N>` (fixed-size byte arrays like `bytes32` or `bytes4`)
- `address`
- Fixed-size arrays (e.g., `uint256[5]`)
- Tuples and Structs (but *only* if all of their internal elements are also fixed-size)

#### Dynamic Types
These types have a variable length that cannot be predicted at compile time. They require a more complex "head and tail" encoding scheme to be packed into 32-byte slots.
- `bytes` (dynamic byte arrays)
- `string`
- Dynamic arrays (e.g., `uint256[]`)
- Fixed-size arrays that contain dynamic types (e.g., `string[5]`)
- Tuples and Structs that contain *any* dynamic types

### Encoding Dynamic Types (The Offset)
Because dynamic types have a variable length, the EVM cannot simply pack them perfectly sequentially into `calldata`. If it did, it wouldn't know where one argument ends and the next one begins.

To solve this, the EVM uses a "Head and Tail" encoding architecture. 
- In the **Head** (the sequential 32-byte slot where the argument *should* be), the EVM stores an **Offset**. 
- The **Offset** is a 32-byte pointer (an integer) that tells the EVM: *"The actual data for this argument doesn't live here. Jump forward X bytes into the calldata to find where the real data starts."*
- The **Tail** (located at that exact offset pointer) contains the actual dynamic data.

#### Example: ABI Encoding a `string`
Because a `string` is a dynamic data type, it strictly requires this Offset architecture. Encoding a single string argument involves exactly three pieces of data (each taking up 32-byte slots):

1. **The Offset (Head):** Located in the normal sequential argument slot, this pointer tells the EVM exactly where the string data begins (e.g., `0x00...0020`, meaning "jump forward 32 bytes").
2. **The Length (Tail Start):** At the location pointed to by the offset, the very first 32-byte word dictates the exact length of the string in bytes (so the EVM knows exactly how much data to read).
3. **The Content:** Immediately following the Length word is the actual UTF-8 encoded string content. If the string is shorter than 32 bytes, it is padded with zeros to perfectly fill out the slot.

## 2. The EVM Execution Context (Call Frames)
Unlike traditional operating systems (like Linux) that spawn new concurrent "processes" with isolated PIDs and virtual memory, the EVM is a strictly single-threaded, synchronous state machine. 

When a transaction triggers a smart contract, the EVM spins up a temporary, lightweight **Execution Context** (often called a **Call Frame**). 

### The Anatomy of a Call Frame
Each Call Frame is granted its own isolated environment for the duration of the function execution:
1. **`calldata`:** The raw, read-only byte payload sent by the transaction sender. 
2. **`memory`:** A fresh, blank linear byte array acting as temporary RAM. It is fully writable.
3. **`storage`:** Access to the permanent blockchain state (the hard drive).

When you use the `memory` keyword in a Solidity parameter (e.g., `function foo(string memory myString)`), the compiler automatically injects opcodes that literally copy the string data out of the read-only `calldata` and paste it into the writable linear `memory` strip before your function logic even begins.

### The EVM is "Blind" (But the Bytecode "Knows")
The EVM itself does not dynamically "figure out" how to split the arguments in the calldata. It is totally blind.

However, the **compiled bytecode knows exactly how to interpret the arguments**. When your contract compiles, the Solidity compiler maps out exactly what data types the function expects, and hardcodes the exact byte-slicing instructions directly into the bytecode. 

1. The **Function Dispatcher** (a giant `switch` statement of `EQ` and `JUMPI` opcodes at the top of the contract) reads the 4-byte selector and jumps to the correct bytecode block.
2. Inside that block, hardcoded `CALLDATALOAD` opcodes instruct the EVM exactly which byte offsets to read (e.g., *"read 32 bytes starting at byte 4"*). 

The EVM simply and blindly follows these hardcoded instructions to unpack the arguments, trusting that the compiler set up the bytecode correctly! 

### Death of the Context
When the Call Frame hits a `RETURN` or `REVERT` opcode, the entire execution context is instantly destroyed. Both the read-only `calldata` and the linear `memory` array are completely wiped clean. The only data that survives the death of the Call Frame is what was explicitly written to permanent `storage`.

## 3. Where is Bytecode Stored? (The Account Object)
It is a common misconception that a contract's compiled bytecode is stored inside its `storage` alongside its state variables. It is not.

In Ethereum, every single address (both User Wallets and Smart Contracts) is represented by an **Account Object** in the global state database. Every Account Object contains exactly 4 fields:
1. **`nonce`:** The number of transactions sent (or contracts created) by the address.
2. **`balance`:** The amount of raw ETH the address holds.
3. **`storageRoot`:** A pointer to the database tree that holds the contract's writable `storage` variables.
4. **`codeHash`:** A pointer to the **immutable compiled bytecode**.

*(Note: For a normal user wallet (EOA), the `codeHash` is simply the hash of an empty string, which is exactly how the EVM knows it is a wallet and not a contract!)*

When a transaction is sent to a smart contract, the EVM looks up the destination address, sees that it has a valid `codeHash`, fetches the immutable bytecode from the database, and executes it. 

Because the `codeHash` is completely structurally separate from the writable `storageRoot`, **bytecode is 100% immutable**. While you can freely update your `storage` variables all day, you can never change the physical bytecode once it is deployed. This permanent immutability is the exact reason why Proxy architectures (which we will cover next) were invented!
