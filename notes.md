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
