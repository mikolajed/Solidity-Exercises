// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

contract ReducingPayout {
    /*
        This exercise assumes you know how block.timestamp works.
        1. This contract has 1 ether in it, each second that goes by, 
           the amount that can be withdrawn by the caller goes from 100% to 0% as 24 hours passes.
        2. Implement your logic in `withdraw` function.
        Hint: 24 hours has 86,400 seconds.
        amountExpected = balance * (86400 - timePassed) / 86400
        where;
        balance: the initial contract balance (1 ether)
        timePassed: the number of seconds passed since the 1 ether was sent to this contract
    */

    // The time 1 ether was sent to this contract
    uint256 public immutable depositedTime;

    constructor() payable {
        depositedTime = block.timestamp;
    }

    function withdraw() public {
        uint256 timePassed = block.timestamp - depositedTime;
        if (timePassed > 86400) {
            timePassed = 86400;
        }
        uint256 amount = (1 ether * (86400 - timePassed)) / 86400;
        if (amount > 0) {
            payable(msg.sender).transfer(amount);
        }
    }
}

