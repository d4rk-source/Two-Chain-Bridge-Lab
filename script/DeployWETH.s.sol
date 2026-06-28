// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/chainB/WETH.sol";

contract DeployWETH is Script {
    function run() external returns (address) {
        vm.startBroadcast();
        WETH w = new WETH("Wrapped Ether", "WETH");
        vm.stopBroadcast();

        console.log("WETH deployed at", address(w));
        return address(w);
    }
}
