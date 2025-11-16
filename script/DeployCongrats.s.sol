// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/Congrats.sol";

contract DeployCongrats is Script {
    function run() external returns (address) {
        vm.startBroadcast();
        Congrats c = new Congrats();
        vm.stopBroadcast();

        console.log("Congrats deployed at", address(c));
        return address(c);
    }
}
