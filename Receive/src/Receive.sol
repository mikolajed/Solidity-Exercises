// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

contract Receive {
    // solidity smart contracts cannot receive
    // ether by default. They need a receive
    receive() external payable {}
}
