# Module 2: Getting Started

## 21. Common Mistakes & Best Practices

- **Avoid `transfer` and `send`**: Historically, `payable(addr).transfer()` and `payable(addr).send()` were used to send Ether. However, they enforce a hard limit of 2300 gas. If the receiving contract requires more gas to execute its fallback/receive function (e.g., due to EVM gas cost changes or complex logic), the transfer will fail. You should always use `(bool success, ) = addr.call{value: amount}("");` and explicitly check the `success` boolean. Alternatively, you can use OpenZeppelin's `Address` library which provides the `sendValue(address payable recipient, uint256 amount)` function, acting as a safe wrapper around the low-level call.
- **Checks-Effects-Interactions (CEI) Pattern**: This is the most critical security pattern in Solidity to prevent Reentrancy attacks. Always structure your functions in this exact order:
  1. **Checks**: Run all `require()` statements to validate conditions (e.g., "Does the user have enough balance?").
  2. **Effects**: Update all internal state variables (e.g., "Deduct the user's balance").
  3. **Interactions**: *Finally*, make external calls to other contracts or send Ether. (Never make an external call before finishing your state updates!).
- **Contract Layout & Ordering**: A standardized layout makes your code readable and professional. The recommended order inside a contract is:
  1. State Variables (Constants first, then regular variables)
  2. Events
  3. Custom Errors
  4. Modifiers
  5. Functions
- **Function Ordering**: Functions should be grouped first by **Visibility**, and then by **Mutability**:
  - **Visibility Order**: `constructor`, `receive`/`fallback`, `external`, `public`, `internal`, `private`.
  - **Mutability Order**: Within each visibility group, list state-changing functions first, followed by `view` functions, and finally `pure` functions.
- **Locking the Pragma Version**: For your main, deployable contracts, you should lock the Solidity pragma version to the exact compiler you intend to use (e.g., `pragma solidity 0.8.28;` instead of blindly using a floating pragma like `^0.8.0;`). This ensures your contract isn't accidentally deployed with a newer, untested compiler version that might introduce bugs or breaking changes.
  - **Exception for Libraries**: When writing reusable libraries or interfaces (like OpenZeppelin contracts), it is best practice to use a floating pragma (e.g., `^0.8.0`) so that other projects aren't artificially restricted to an exact compiler version when importing your code.
- **Consistent Formatting**: Always use `forge fmt` to automatically format your Solidity code before committing. This enforces a standardized, clean, and readable layout across your entire codebase, avoiding stylistic inconsistencies.
