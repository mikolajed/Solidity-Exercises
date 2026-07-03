// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

contract Deployer {
    string public greeting;

    constructor(string memory _greeting) {
        require(bytes(_greeting).length > 0, "greeting cannot be empty");
        greeting = _greeting;
    }
}
