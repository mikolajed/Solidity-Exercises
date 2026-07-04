// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

contract Tupledore {
    struct UserInfo {
        address userAddress;
        uint256 id;
    }

    UserInfo public userInfo;

    function setTuple(address _userAddress, uint256 _id) public {
        userInfo = UserInfo(_userAddress, _id);
    }

    function returnTuple() public view returns (address, uint256) {
        return (userInfo.userAddress, userInfo.id);
    }
}
