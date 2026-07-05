# Solidity Surprises: Key Learnings & Observations

As I have worked through various exercises, I have encountered a few aspects of Solidity that deviate from traditional programming languages. Here is a curated list of interesting findings and best practices to keep in mind:

## 1. Nested Arrays: Declaration vs. Access

The syntax for declaring a nested array can be unintuitive compared to how you access it later. For example, when declaring `uint256[2][]`, it means a dynamic array where each element is an array of 2 integers. However, when you access it as `myArray[i][j]`, `i` indexes the outer dynamic array, and `j` indexes the inner fixed-size array.

## 2. The Ephemeral Nature of `memory`

The `memory` keyword designates a temporary, linear storage area. It exists solely for the lifespan of a function execution. Once the function (and any sequence of internal calls) completes, this memory is entirely wiped clean.

## 3. The Cost of Appending to Arrays

Adding items to dynamic arrays within a contract can become prohibitively expensive. In Solidity, memory expansion costs scale quadratically. If you are frequently pushing to arrays or copying them, the gas costs can spiral out of control very quickly.

## 4. Mappings are Strictly `storage`

Unlike other data structures, `mapping`s are restricted to `storage` only. You cannot instantiate a mapping in `memory`, pass them as memory arguments, or return them from public functions. They inherently define state on the blockchain.

## 5. Bypassing Reverts with `unchecked`

Since version 0.8.0, Solidity automatically halts (reverts) if an arithmetic operation causes an overflow or underflow. If you are absolutely certain that an operation is safe and you want to save gas (or explicitly desire wrap-around behavior), you can wrap the calculation in an `unchecked { ... }` block to prevent the transaction from halting.

## 6. The Absence of Floating-Point Numbers

Solidity does not support floats (e.g., `1.5`). This is a deliberate design choice to ensure determinism across the EVM; different machines might handle floating-point math slightly differently, which would cause the blockchain nodes to disagree on the state. To work around this, always perform multiplication before division (e.g., `(a * 100) / b` instead of `(a / b) * 100`).

## 7. Unsigned Integers Dominate

While signed integers (`int`) exist, standard practice heavily favors unsigned integers (`uint`), meaning numbers cannot be negative. You have to explicitly manage logic that might drop below zero to avoid underflow errors.

## 8. Strings Cannot Be Indexed Directly

You cannot access a character in a string using an index (like `myString[0]`). Strings in Solidity are fundamentally dynamic sequences of bytes designed to support complex UTF-8 encoding (like emojis or special characters). Direct indexing could split multi-byte characters, leading to corrupted data and potential consensus disagreements between nodes.

## 9. Rare Usage of `while` and `do-while`

Although `while` and `do-while` loops are supported by the language syntax, you will rarely see them in production code. Unbounded loops run the severe risk of exceeding the block gas limit, causing the transaction to fail and wasting the user's gas.

## 10. The `_underscore` Parameter Convention

A widely adopted naming convention in the Solidity community is to prefix constructor arguments and function parameters with an underscore (e.g., `_owner` or `_initialValue`). This helps developers visually distinguish local inputs from the contract's permanent state variables.

## 11. ERC20 `decimals` Should Be `uint8`

In the ERC20 token standard, the `decimals` function defines the number of decimal places the token uses. This value is strictly expected to be a `uint8` (an unsigned 8-bit integer, max value 255). Because Solidity does not support floating-point numbers, `decimals` are used by user interfaces to know how to display the token balances correctly. For example, if a token uses 18 decimals (the standard for Ether and many ERC20s), a balance of `1500000000000000000` in the smart contract will be displayed to the user as `1.5` tokens.

## 12. Address Zero and Token Burning

In ERC20 and other token standards, you should generally prevent transferring tokens directly to the zero address (`address(0)`). While this is often used as a mechanism to "burn" tokens (removing them from circulation permanently), a standard transfer to `address(0)` does not automatically decrease the contract's `totalSupply` state variable. To correctly burn tokens, the contract should have a dedicated `burn` function that deducts the balance from the sender and intentionally decreases `totalSupply` to ensure the overall tracking of tokens remains accurate.

## 13. ABI Encoding & Decoding Functions

Solidity provides several built-in functions under `abi` for converting variables to raw bytes and vice versa, especially useful when making low-level calls or interacting with external contracts:

- **`abi.encode(...)`**: Standard ABI encoding. Takes any number of arguments of any type and encodes them into `bytes`, padding each variable to 32-byte slots per the ABI specification.
- **`abi.decode(bytes data, (types...))`**: Reverses `abi.encode`. Decodes raw `bytes` data back into a tuple of specific types (e.g., `(string memory, uint256)`).
- **`abi.encodeWithSignature("funcName(type1,type2)", arg1, arg2)`**: Takes a function signature as a raw string (without spaces or variable names, e.g., `"transfer(address,uint256)"`), derives its 4-byte function selector via `bytes4(keccak256(...))`, and prepends it to the ABI-encoded parameters.
- **`abi.encodeWithSelector(bytes4 selector, arg1, arg2)`**: Functions identically to `encodeWithSignature`, but accepts the 4-byte function selector directly (e.g., `IERC20.transfer.selector` or `bytes4(keccak256("transfer(address,uint256)"))`). This is preferred as it avoids typos in string signatures at compile time.

## 14. High-Level Contract Calls vs. Low-Level `.call()`

When interacting with other contracts, you generally have two approaches:

**High-Level Calls**
This is the recommended approach for most interactions.

- **Type Safety**: The compiler verifies the function name, parameters, and return types. Typos cause compile-time errors.
- **Automatic Reverts**: If the target contract reverts, the calling function automatically reverts and bubbles up the error.
- **Automatic Decoding**: Return values are automatically decoded into the correct types.
- **State Protection**: The compiler enforces `staticcall` for `view` functions, preventing accidental state modifications.

**Low-Level Calls (e.g., `_oracle.call(abi.encodeWithSignature(...))`)**
This approach operates on raw bytes and bypasses type checking. It should be used only in specific scenarios:

- **Sending ETH**: Using `target.call{value: amount}("")` is the standard way to send Ether.
- **Handling Graceful Failures**: `.call()` returns a boolean `(bool success, bytes memory data)`. It does not automatically revert if the call fails, allowing you to catch the failure and continue execution (e.g., trying optional features).
- **Unknown ABIs**: When building generic proxy contracts or interacting with contracts whose interfaces are not known at compile time.

## 15. Sending Ether: `.transfer` vs `.call` and `payable`

In Solidity, to send Ether to an address, that address must be explicitly cast to `payable` (e.g., `payable(msg.sender)`). If an address is not marked as `payable`, the compiler will prevent you from sending funds to it.

There are two common ways to send Ether:

- **`payable(addr).transfer(amount)`**: This is the older, simpler method. It automatically reverts the transaction if the transfer fails. However, it imposes a strict 2300 gas limit on the receiving contract's fallback/receive function, which can break if the receiver contains complex logic or if EVM gas costs change.
- **`addr.call{value: amount}("")`**: This is the modern, recommended approach for sending Ether. It forwards all available gas to the recipient, allowing for complex execution. It returns a boolean indicating success (`(bool success, ) = addr.call...`) and does _not_ automatically revert if the transfer fails, meaning you must manually check the `success` value (or explicitly ignore it) to handle failures appropriately.

## 16. Global Variables and Time Units

Solidity provides several built-in global variables and units that are particularly useful for time-locked and block-based logic:

- **`block.timestamp`**: Returns the current block's timestamp as seconds since the Unix epoch. It's the standard way to handle time in smart contracts (e.g., locking funds until a certain date). Note that miners/validators have slight leeway in manipulating this value (by a few seconds), so it shouldn't be used as a strict source of randomness.
- **`block.number`**: Returns the current block's height (the number of the block). This is often used for governance voting periods or to prevent a function from being executed multiple times within the exact same block.
- **Time Units**: Solidity natively supports time suffixes such as `seconds`, `minutes`, `hours`, `days`, and `weeks`. When you use these suffixes after a literal number, they automatically multiply the number by the corresponding amount of seconds.

## 17. Events and Indexing

Events in Solidity are used to log information to the blockchain in a gas-efficient way. They are primarily designed for **off-chain retrieval**, enabling frontend applications (like dApps) to easily search and listen for specific contract actions without having to constantly query the contract state.

- **Not Strictly Necessary for On-Chain Logic**: Smart contracts cannot read event logs. Events don't affect state; they are purely for external applications to monitor what happened.
- **Indexing Parameters**: You can add the `indexed` keyword to up to **3 parameters** in an event. This allows external apps to filter logs based on those specific parameters (e.g., finding all `Transfer` events where `to == myAddress`).
- **Standard Specifications**: While optional for custom logic, established token standards (like ERC20, ERC721) strictly *require* specific events to be emitted. For instance, the ERC20 standard requires emitting a `Transfer(address indexed from, address indexed to, uint256 value)` event on all transfers.
- **`address(0)` in Events**: When logging the creation of new tokens (minting), standard convention dictates setting the `from` address as `address(0)`. This visually signifies to off-chain observers that the token "came from nothing" and was newly minted into circulation. Similarly, burning tokens emits a transfer to `address(0)`.

## 18. Inheritance

- **Multiple Inheritance**: A contract can inherit multiple parents: `contract Child is Parent1, Parent2 { ... }`. Order matters (base to derived).
- **`virtual` & `override`**: A parent marks a function `virtual` to allow it to be replaced. The child uses `override` when replacing it.
- **`super`**: Use `super.funcName()` inside a child contract to execute the parent's version of that function.
- **`private` vs `internal`**: `private` means access is restricted strictly to the defining contract. `internal` allows access in the defining contract *and* any child contracts (like `protected` in C++/Java).
