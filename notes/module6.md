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

## 4. Storage Slots in Solidity: Storage Allocation and Low-level Assembly Storage Operations

### Smart Contract Storage Architecture
Variables in a smart contract store their value in two primary locations: **storage** and **bytecode**.

#### Bytecode (Immutable)
The bytecode stores immutable information. This includes the values of `immutable` and `constant` variable types. Because they are baked directly into the physical bytecode at compile time, they do not take up any storage slots, and reading them is significantly cheaper than reading from state.

#### Storage (Mutable)
The storage holds mutable information. Variables that store their value in the storage are called **state variables** or **storage variables**.
When we interact with a storage variable in Solidity, under the hood, we are actually reading and writing from the global Ethereum database, specifically at the exact **storage slot** where the variable keeps its value.

### Anatomy of a Storage Slot
A smart contract’s storage is organized into an astronomically large dictionary of storage slots. Each individual slot has a fixed storage capacity of exactly **256 bits (32 bytes)**. A contract has access to $2^{256}$ of these slots.

#### Inside Storage Slots: 256-bit Data
Variables are assigned to these slots based on their data type:
- **Primitive Datatypes:** Basic types like `uint256`, `address`, and `bool` are stored sequentially starting from Slot 0. If multiple primitive variables are small enough (e.g., two `uint128`s), the compiler will tightly pack them into a single 256-bit slot to save gas.
- **Complex Datatypes:** Types such as structs (`struct{}`), dynamic arrays (`array[]`), mappings (`mapping(address => uint256)`), strings (`string`), and dynamic bytes (`bytes`) have a much more complicated storage slot allocation relying heavily on Keccak-256 hashing. *(Note: The exact allocation rules for complex datatypes require a dedicated deep dive).*

### Storage Packing
When you declare primitive state variables in Solidity, the compiler assigns them sequentially to storage slots, starting at **Slot 0**, then **Slot 1**, and so forth.

Because interacting with storage (`SSTORE` and `SLOAD`) is highly expensive, the Solidity compiler attempts to optimize this by **packing** multiple small variables into a single 32-byte (256-bit) slot.

#### How Packing Works
If a variable takes up less than 32 bytes (for example, a `uint128` is only 16 bytes, and an `address` is 20 bytes), the compiler will check if the *next* variable declared in the code can also fit into the remaining space in the current slot. If it can, they are packed together. If it cannot, the compiler skips the remaining space and starts a fresh slot.

**Example of Good Packing (2 Slots):**
```solidity
uint128 a; // 16 bytes -> Fits in Slot 0
uint128 b; // 16 bytes -> Fits perfectly in Slot 0!
uint256 c; // 32 bytes -> Too big. Starts Slot 1
```
In this scenario, `a` and `b` share Slot 0. Reading both variables together is cheaper because it only requires one `SLOAD`.

#### Order Matters
The Solidity compiler reads your variables strictly top-to-bottom. It will **not** magically reorder your variables to optimize packing for you. 

**Example of Bad Packing (3 Slots):**
```solidity
uint128 a; // 16 bytes -> Starts Slot 0
uint256 b; // 32 bytes -> Doesn't fit in Slot 0! Starts Slot 1.
uint128 c; // 16 bytes -> Starts Slot 2.
```
Even though `a` and `c` could perfectly fit into a single slot together, the massive `uint256` in the middle breaks the sequence. This contract takes up 3 storage slots instead of 2, significantly increasing deployment and operational gas costs!

### Low-level Assembly Storage Operations (Yul)
Low-level assembly (Yul) gives developers a much higher degree of freedom in performing storage-related operations. It allows us to bypass Solidity's strict typing and directly read or write to individual raw storage slots.

**Important Note on Yul Types:** In assembly, Solidity's rich type system (`uint8`, `address`, `bool`) does not exist. Every single variable in Yul is essentially treated as a raw `bytes32` (a 256-bit word). If you are reading a slot that contains multiple packed variables, Yul will just hand you the entire 32-byte block, and it is up to you to manually bit-shift and mask the data to extract the specific variable you want!

When using Yul blocks (`assembly { ... }`), we can access two hidden properties of any state variable:
1. `variable.slot`: Returns the exact numeric storage slot (e.g., `0`, `1`) where the variable is stored.
2. `variable.offset`: If the variable is tightly packed into a slot with other variables, this returns the byte offset (from right-to-left) where this specific variable starts inside the 32-byte slot.

Using these properties, you can use the raw EVM opcodes to manipulate the database:
- **`sload(slot)`**: Reads the entire 32-byte chunk of data from the given slot.
- **`sstore(slot, value)`**: Writes an entire 32-byte chunk of data into the given slot.

**Example: Reading and Writing with Yul**
```solidity
uint256 public myNumber = 42;

// Reading from Storage
function readStorageDirectly() public view returns (uint256 data) {
    assembly {
        // Find the slot number for myNumber (which is Slot 0)
        let slotNum := myNumber.slot
        // Read the raw 32 bytes from Slot 0
        data := sload(slotNum) 
    }
}

// Writing to Storage
function writeStorageDirectly(uint256 newValue) public {
    assembly {
        // Find the slot number for myNumber
        let slotNum := myNumber.slot
        // Overwrite the entire 32-byte chunk at Slot 0 with the newValue
        sstore(slotNum, newValue)
    }
}
```
*(Warning: If `myNumber` was packed with other variables in Slot 0, using a raw `sstore` like this would blindly overwrite and destroy the other variables sharing the slot! You would need to use bitwise operations to safely update only a portion of the slot. Furthermore, **`sstore()` does not type check.** Because Yul ignores Solidity's type system, it will happily let you write random bytes into a slot that Solidity expects to be a boolean, permanently breaking your contract logic if you aren't careful!)*

## 5. Low Level Call vs High Level Call in Solidity

A contract in Solidity can interact with and execute functions on other contracts via two distinct methods: 
1. **High-Level Call:** Calling through a defined contract interface (e.g., `IERC20(token).transfer()`).
2. **Low-Level Call:** Using the raw `.call()` method directly on an address (e.g., `address.call(...)`).

Despite both methods ultimately compiling down to the exact same `CALL` opcode at the EVM level, the Solidity compiler treats them drastically differently in terms of syntax, type safety, and error handling.

### Error Handling (The Revert Illusion)
One of the most critical differences is how failures are handled. 

At the raw EVM level, the `CALL` opcode **does not revert the transaction if it fails**. If a contract calls another contract and the destination contract crashes, the `CALL` opcode simply catches the crash, stops it from bubbling up, and pushes a `false` (0) boolean onto the execution stack. It is entirely up to the caller to check that boolean and decide what to do next.

- **High-Level Calls (Automatic Revert):** When you use a high-level interface, the Solidity compiler automatically injects extra bytecode immediately after the `CALL` opcode to check that boolean. If the boolean is `false`, the injected bytecode forces your contract to `REVERT`. This makes high-level calls inherently safe.
- **Low-Level Calls (Manual Check Required):** When you use a low-level `.call()`, the compiler does *not* inject the safety check. It just hands you the boolean and the return data. If the call fails and you forget to manually `require(success)`, your contract will silently continue executing as if everything succeeded, which is a massive and common security vulnerability!

### The "Empty Address" Trap
A bizarre quirk of the EVM is how it handles calling an address that has absolutely no bytecode (such as an empty address, an EOA wallet, or the zero address). At the raw EVM level, **a `CALL` to an empty address always returns `true` for success!** 

- **High-Level Calls (Existence Check):** To protect you from this EVM quirk, high-level interface calls automatically inject an `extcodesize` check *before* making the call. If the target address has a code size of 0, the injected bytecode forces the transaction to revert immediately, refusing to make the call.
- **Low-Level Calls (No Existence Check):** A low-level `.call()` does *not* perform a prior check to verify whether the called address corresponds to a contract. If you accidentally pass an empty address, the low-level call will silently execute, do absolutely nothing, and return `success = true`. If you rely on that boolean without manually verifying the contract's existence first, your app will falsely assume it successfully executed a function that didn't even exist!
