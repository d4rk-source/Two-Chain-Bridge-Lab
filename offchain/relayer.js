#!/usr/bin/env node
"use strict";
/**
 * Relayer
 * Listens for `SwapLocked(address indexed sender, uint256 amount)` events on Chain A
 * and calls `bridge(address to, uint256 amount)` on Chain B using the event values.
 *
 * Environment variables (set these before running):
 *  - CHAIN_A_RPC        RPC URL for Chain A (where LockAndSwap is deployed)
 *  - CHAIN_B_RPC        RPC URL for Chain B (where WETH/bridge is deployed)
 *  - CHAIN_A_CONTRACT   LockAndSwap contract address on Chain A
 *  - CHAIN_B_CONTRACT   WETH contract address on Chain B
 *  - PRIVATE_KEY_B      Private key used to sign transactions on Chain B
 *
 * Example:
 *  CHAIN_A_RPC=http://127.0.0.1:8545 \
 *  CHAIN_B_RPC=http://127.0.0.1:9545 \
 *  CHAIN_A_CONTRACT=0x... \
 *  CHAIN_B_CONTRACT=0x... \
 *  PRIVATE_KEY_B=0x... \
 *  node offchain/relayer.js
 */

let ethersPkg = require("ethers");
if (ethersPkg.ethers) ethersPkg = ethersPkg.ethers;
const ethers = ethersPkg;

// Load .env if present (optional)
try {
  require('dotenv').config();
} catch (e) {
  // dotenv is optional; ignore if not installed
}

// Configuration from environment variables with sensible defaults for local dev
const CHAIN_A_RPC = process.env.CHAIN_A_RPC || "http://127.0.0.1:8545";
const CHAIN_B_RPC = process.env.CHAIN_B_RPC || "http://127.0.0.1:8546";
const CHAIN_A_CONTRACT = process.env.CHAIN_A_CONTRACT || "0x5FbDB2315678afecb367f032d93F642f64180aa3";
const CHAIN_B_CONTRACT = process.env.CHAIN_B_CONTRACT || "0x5FbDB2315678afecb367f032d93F642f64180aa3";
const PRIVATE_KEY_B = process.env.PRIVATE_KEY_B || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const STATE_FILE = process.env.RELAYER_STATE_FILE || "offchain/relayer_state.json";

if (!CHAIN_A_CONTRACT) {
  console.error("Missing CHAIN_A_CONTRACT (LockAndSwap address on Chain A)");
  process.exit(1);
}
if (!CHAIN_B_CONTRACT) {
  console.error("Missing CHAIN_B_CONTRACT (WETH/bridge address on Chain B)");
  process.exit(1);
}
if (!PRIVATE_KEY_B) {
  console.error("Missing PRIVATE_KEY_B (private key to sign on Chain B)");
  process.exit(1);
}

// Minimal ABIs
const LOCK_AND_SWAP_ABI = [
  "event SwapLocked(address indexed sender, uint256 amount)"
];

const WETH_BRIDGE_ABI = [
  "function bridge(address to, uint256 amount)",
  // burn is owner-only on the WETH contract
  "function burn(address from, uint256 amount)"
];

// Also listen for Withdraw events emitted by LockAndSwap (user or owner withdrawals)
LOCK_AND_SWAP_ABI.push("event Withdraw(address indexed account, uint256 amount)");

async function main() {
  const providerA = new ethers.JsonRpcProvider(CHAIN_A_RPC);
  const providerB = new ethers.JsonRpcProvider(CHAIN_B_RPC);

  const contractA = new ethers.Contract(CHAIN_A_CONTRACT, LOCK_AND_SWAP_ABI, providerA);
  const walletB = new ethers.Wallet(PRIVATE_KEY_B, providerB);
  const contractB = new ethers.Contract(CHAIN_B_CONTRACT, WETH_BRIDGE_ABI, providerB).connect(walletB);

  console.log("Relayer configured:");
  console.log(" Chain A RPC:", CHAIN_A_RPC);
  console.log(" Chain B RPC:", CHAIN_B_RPC);
  console.log(" Chain A contract:", CHAIN_A_CONTRACT);
  console.log(" Chain B contract:", CHAIN_B_CONTRACT);
  console.log(" Listening for SwapLocked events on Chain A...");

  // persisted processed tx hashes to avoid double-processing
  const stateFile = STATE_FILE;
  let processed = new Set();
  try {
    const s = require("fs").readFileSync(stateFile, "utf8");
    const parsed = JSON.parse(s || "[]");
    parsed.forEach((h) => processed.add(h));
  } catch (e) {
    // ignore missing file
  }

  function persistProcessed() {
    try {
      require("fs").writeFileSync(stateFile, JSON.stringify(Array.from(processed), null, 2));
    } catch (e) {
      console.error("Failed to persist state:", e);
    }
  }

  async function handleEvent(sender, amount, event) {
    const txHash = event && event.transactionHash ? event.transactionHash : null;
    if (txHash && processed.has(txHash)) {
      console.log("Skipping already-processed event tx:", txHash);
      return;
    }

    try {
      console.log("\n[Event] SwapLocked - sender:", sender, "amount:", amount.toString(), "tx:", txHash);

      // Call bridge on Chain B with the same values
      console.log("Calling bridge on Chain B -> to:", sender, "amount:", amount.toString());
      const tx = await contractB.bridge(sender, amount, { gasLimit: 300000 });
      console.log("Sent bridge tx:", tx.hash);
      const receipt = await tx.wait();
      console.log("Bridge tx confirmed. status:", receipt.status);

      if (txHash) {
        processed.add(txHash);
        persistProcessed();
      }
    } catch (err) {
      console.error("Error handling SwapLocked event:", err);
    }
  }

  async function handleWithdrawEvent(account, amount, event) {
    const txHash = event && event.transactionHash ? event.transactionHash : null;
    if (txHash && processed.has(txHash)) {
      console.log("Skipping already-processed withdraw event tx:", txHash);
      return;
    }

    try {
      console.log("\n[Event] Withdraw - account:", account, "amount:", amount.toString(), "tx:", txHash);

      // Call burn on Chain B WETH contract to reflect withdraw (burn tokens from account)
      console.log("Calling burn on Chain B -> from:", account, "amount:", amount.toString());
      const tx = await contractB.burn(account, amount, { gasLimit: 300000 });
      console.log("Sent burn tx:", tx.hash);
      const receipt = await tx.wait();
      console.log("Burn tx confirmed. status:", receipt.status);

      if (txHash) {
        processed.add(txHash);
        persistProcessed();
      }
    } catch (err) {
      console.error("Error handling Withdraw event:", err);
    }
  }

  // catch up on past events (in case relayer started after events were emitted)
  try {
    const filter = contractA.filters ? contractA.filters.SwapLocked() : null;
    if (filter) {
      const fromBlock = 0; // consider starting from a saved block number for production
      const events = await contractA.queryFilter(filter, fromBlock, "latest");
      if (events && events.length) console.log("Processing", events.length, "historical events...");
      for (const ev of events) {
        // ev.args: [sender, amount]
        await handleEvent(ev.args[0], ev.args[1], ev);
      }
    }
  } catch (e) {
    console.error("Error during catch-up event processing:", e);
  }

  // Also catch-up Withdraw events
  try {
    const withdrawFilter = contractA.filters ? contractA.filters.Withdraw() : null;
    if (withdrawFilter) {
      const fromBlock = 0;
      const wEvents = await contractA.queryFilter(withdrawFilter, fromBlock, "latest");
      if (wEvents && wEvents.length) console.log("Processing", wEvents.length, "historical Withdraw events...");
      for (const ev of wEvents) {
        // ev.args: [account, amount]
        await handleWithdrawEvent(ev.args[0], ev.args[1], ev);
      }
    }
  } catch (e) {
    console.error("Error during Withdraw catch-up processing:", e);
  }

  // Listen for SwapLocked events (live)
  contractA.on("SwapLocked", handleEvent);
  // Listen for Withdraw events (live)
  contractA.on("Withdraw", handleWithdrawEvent);

  // Graceful shutdown
  process.on("SIGINT", () => {
    console.log("Shutting down relayer...");
    contractA.removeAllListeners("SwapLocked");
    process.exit(0);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
