// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Congrats {
    event Reached(string message);

    function reach() external {
        emit Reached("congrats, you reached me");
    }
}
