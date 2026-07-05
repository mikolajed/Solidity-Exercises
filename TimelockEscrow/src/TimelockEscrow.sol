// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

contract TimelockEscrow {
    address public seller;

    /**
     * The goal of this exercise is to create a Time lock escrow.
     * A buyer deposits ether into a contract, and the seller cannot withdraw it until 3 days passes. Before that, the buyer can take it back
     * Assume the owner is the seller
     */

    constructor() {
        seller = msg.sender;
    }

    struct Escrow {
        uint256 amount;
        uint256 lockedUntil;
    }
    mapping(address => Escrow) public escrows;

    function createBuyOrder() external payable {
        require(escrows[msg.sender].amount == 0, "Active escrow exists");
        escrows[msg.sender] = Escrow({
            amount: msg.value,
            lockedUntil: block.timestamp + 3 days
        });
    }

    function sellerWithdraw(address buyer) external {
        require(msg.sender == seller, "Only seller");
        Escrow memory escrow = escrows[buyer];
        require(escrow.amount > 0, "No active escrow");
        require(block.timestamp >= escrow.lockedUntil, "Still locked");
        delete escrows[buyer];
        payable(seller).transfer(escrow.amount);
    }

    function buyerWithdraw() external {
        Escrow memory escrow = escrows[msg.sender];
        require(escrow.amount > 0, "No active escrow");
        require(block.timestamp < escrow.lockedUntil, "Lock expired");
        delete escrows[msg.sender];
        payable(msg.sender).transfer(escrow.amount);
    }

    function buyerDeposit(address buyer) external view returns (uint256) {
        return escrows[buyer].amount;
    }
}
