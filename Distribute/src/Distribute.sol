// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

contract Distribute {
    /*
        This exercise assumes you know how to sending Ether.
        1. This contract has some ether in it, distribute it equally among the
           array of addresses that is passed as argument.
        2. Write your code in the `distributeEther` function.
    */

    constructor() payable {}

    function distributeEther(address[] memory addresses) public {
        require(addresses.length > 0, "No addresses");
        uint256 amountPerAddress = address(this).balance / addresses.length;
        for (uint256 i = 0; i < addresses.length; i++) {
            payable(addresses[i]).transfer(amountPerAddress);
        }
    }
}
