// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/chain A/LockAndSwap.sol";

contract DeployLockAndSwap is Script {
    function run() external returns (address) {
        vm.startBroadcast();
        LockAndSwap s = new LockAndSwap();
        vm.stopBroadcast();

        console.log("LockAndSwap deployed at", address(s));
        return address(s);
    }
}
