#!/usr/bin/env node
"use strict";

/**
 * Cross-Chain Relayer
 *
 * Bridges events from Chain A → Chain B:
 *   SwapLocked  → bridge(to, amount)   mints WETH on Chain B
 *   Withdraw    → burn(from, amount)   burns WETH on Chain B
 *
 * Event delivery: uses an explicit poll loop (queryFilter on an interval) rather
 * than contract.on(). JSON-RPC HTTP providers in ethers v6 don't guarantee that
 * the internal event-polling loop stays active, so polling manually is simpler
 * and more reliable.
 *
 * Deduplication: processed tx hashes are persisted to a JSON file so the
 * relayer can restart without double-processing events.
 *
 * Catch-up: on startup, all events from the last saved block are replayed so
 * no events are missed during downtime.
 *
 * Required environment variables:
 *   CHAIN_A_RPC        RPC URL for Chain A (LockAndSwap)
 *   CHAIN_B_RPC        RPC URL for Chain B (WETH)
 *   CHAIN_A_CONTRACT   LockAndSwap address on Chain A
 *   CHAIN_B_CONTRACT   WETH address on Chain B
 *   PRIVATE_KEY_B      Private key used to sign transactions on Chain B
 *
 * Optional:
 *   RELAYER_STATE_FILE  Path for the dedup/state JSON file (default: offchain/relayer_state.json)
 *   POLL_INTERVAL_MS    How often to poll Chain A for new events in ms (default: 2000)
 */

// Support both ethers v5 and v6 module layouts
let ethersPkg = require("ethers");
if (ethersPkg.ethers) ethersPkg = ethersPkg.ethers;
const ethers = ethersPkg;

// Load .env if present (optional dependency)
try { require("dotenv").config(); } catch (_) {}

// -------------------------------------------------------------------------
// Config
// -------------------------------------------------------------------------

const CHAIN_A_RPC       = process.env.CHAIN_A_RPC        || "http://127.0.0.1:8545";
const CHAIN_B_RPC       = process.env.CHAIN_B_RPC        || "http://127.0.0.1:8546";
const CHAIN_A_CONTRACT  = process.env.CHAIN_A_CONTRACT   || "";
const CHAIN_B_CONTRACT  = process.env.CHAIN_B_CONTRACT   || "";
const PRIVATE_KEY_B     = process.env.PRIVATE_KEY_B      || "";
const STATE_FILE        = process.env.RELAYER_STATE_FILE || "offchain/relayer_state.json";
const POLL_INTERVAL_MS  = Number(process.env.POLL_INTERVAL_MS) || 2000;

const RETRY_ATTEMPTS = 3;
const RETRY_BASE_MS  = 1000; // first retry after 1 s; doubles each attempt

// Minimal ABIs — only the signatures the relayer needs
const LOCK_AND_SWAP_ABI = [
  "event SwapLocked(address indexed sender, uint256 amount)",
  "event Withdraw(address indexed account, uint256 amount)",
];

const WETH_ABI = [
  "function bridge(address to, uint256 amount)",
  "function burn(address from, uint256 amount)",
];

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

function ts() { return new Date().toISOString(); }
function log(...args)  { console.log(`[${ts()}]`, ...args); }
function warn(...args) { console.warn(`[${ts()}] WARN`, ...args); }
function err(...args)  { console.error(`[${ts()}] ERROR`, ...args); }

/** Persist state to disk. */
function saveState(processed, lastBlock) {
  try {
    require("fs").writeFileSync(
      STATE_FILE,
      JSON.stringify({ processed: Array.from(processed), lastBlock }, null, 2)
    );
  } catch (e) {
    warn("Failed to persist state:", e.message);
  }
}

/** Load previously persisted state. */
function loadState() {
  try {
    const raw = require("fs").readFileSync(STATE_FILE, "utf8");
    const parsed = JSON.parse(raw || "{}");
    return {
      processed: new Set(Array.isArray(parsed) ? parsed : (parsed.processed || [])),
      lastBlock:  typeof parsed.lastBlock === "number" ? parsed.lastBlock : 0,
    };
  } catch (_) {
    return { processed: new Set(), lastBlock: 0 };
  }
}

/**
 * Call an async function with exponential-backoff retry.
 * @param {() => Promise<any>} fn
 * @param {string} label  Used in warning messages.
 */
async function withRetry(fn, label) {
  for (let attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt === RETRY_ATTEMPTS) throw e;
      const delay = RETRY_BASE_MS * 2 ** (attempt - 1);
      warn(`${label} failed (attempt ${attempt}/${RETRY_ATTEMPTS}), retrying in ${delay}ms:`, e.message);
      await new Promise((r) => setTimeout(r, delay));
    }
  }
}

// -------------------------------------------------------------------------
// Validation
// -------------------------------------------------------------------------

function validateConfig() {
  const missing = [];
  if (!CHAIN_A_CONTRACT) missing.push("CHAIN_A_CONTRACT");
  if (!CHAIN_B_CONTRACT) missing.push("CHAIN_B_CONTRACT");
  if (!PRIVATE_KEY_B)    missing.push("PRIVATE_KEY_B");
  if (missing.length) {
    err("Missing required environment variables:", missing.join(", "));
    process.exit(1);
  }
}

// -------------------------------------------------------------------------
// Event handlers
// -------------------------------------------------------------------------

async function handleSwapLocked(contractB, processed, sender, amount, txHash) {
  if (txHash && processed.has(txHash)) {
    log(`[SwapLocked] Already processed, skipping tx ${txHash}`);
    return;
  }

  log(`[SwapLocked] sender=${sender} amount=${ethers.formatEther(amount)} ETH tx=${txHash}`);

  await withRetry(async () => {
    const tx = await contractB.bridge(sender, amount, { gasLimit: 300_000 });
    log(`[SwapLocked] bridge() sent: ${tx.hash}`);
    const receipt = await tx.wait();
    log(`[SwapLocked] bridge() confirmed: status=${receipt.status}`);
  }, "bridge()");

  if (txHash) processed.add(txHash);
}

async function handleWithdraw(contractB, processed, account, amount, txHash) {
  if (txHash && processed.has(txHash)) {
    log(`[Withdraw] Already processed, skipping tx ${txHash}`);
    return;
  }

  log(`[Withdraw] account=${account} amount=${ethers.formatEther(amount)} ETH tx=${txHash}`);

  await withRetry(async () => {
    const tx = await contractB.burn(account, amount, { gasLimit: 300_000 });
    log(`[Withdraw] burn() sent: ${tx.hash}`);
    const receipt = await tx.wait();
    log(`[Withdraw] burn() confirmed: status=${receipt.status}`);
  }, "burn()");

  if (txHash) processed.add(txHash);
}

// -------------------------------------------------------------------------
// Poll loop
// -------------------------------------------------------------------------

/**
 * Query Chain A for all new events since lastBlock.current, process them,
 * then advance lastBlock to the latest block seen.
 *
 * Using queryFilter on an interval instead of contract.on() because
 * JsonRpcProvider (HTTP) does not reliably maintain an active event-poll loop
 * in ethers v6 — explicit polling is simpler and more predictable.
 */
async function poll(contractA, contractB, processed, lastBlock) {
  let head;
  try {
    head = await contractA.runner.provider.getBlockNumber();
  } catch (e) {
    warn("Could not fetch block number:", e.message);
    return;
  }

  if (head <= lastBlock.current) return;

  const from = lastBlock.current + 1;
  const to   = head;

  try {
    const swapEvents = await contractA.queryFilter(contractA.filters.SwapLocked(), from, to);
    for (const ev of swapEvents) {
      await handleSwapLocked(contractB, processed, ev.args[0], ev.args[1], ev.transactionHash);
    }
  } catch (e) {
    err("Error querying SwapLocked events:", e.message);
  }

  try {
    const withdrawEvents = await contractA.queryFilter(contractA.filters.Withdraw(), from, to);
    for (const ev of withdrawEvents) {
      await handleWithdraw(contractB, processed, ev.args[0], ev.args[1], ev.transactionHash);
    }
  } catch (e) {
    err("Error querying Withdraw events:", e.message);
  }

  lastBlock.current = to;
  saveState(processed, lastBlock.current);
}

// -------------------------------------------------------------------------
// Main
// -------------------------------------------------------------------------

async function main() {
  validateConfig();

  const providerA = new ethers.JsonRpcProvider(CHAIN_A_RPC);
  const providerB = new ethers.JsonRpcProvider(CHAIN_B_RPC);
  const walletB   = new ethers.Wallet(PRIVATE_KEY_B, providerB);

  const contractA = new ethers.Contract(CHAIN_A_CONTRACT, LOCK_AND_SWAP_ABI, providerA);
  const contractB = new ethers.Contract(CHAIN_B_CONTRACT, WETH_ABI, walletB);

  log("Relayer started");
  log("  Chain A RPC:", CHAIN_A_RPC);
  log("  Chain B RPC:", CHAIN_B_RPC);
  log("  Chain A contract:", CHAIN_A_CONTRACT);
  log("  Chain B contract:", CHAIN_B_CONTRACT);
  log("  Poll interval:", POLL_INTERVAL_MS, "ms");

  const { processed, lastBlock: savedBlock } = loadState();
  const lastBlock = { current: savedBlock };

  log(`  State: ${processed.size} processed tx(s), last block ${lastBlock.current}`);

  // -------------------------------------------------------------------------
  // Historical catch-up (block 0 → now, or last saved block → now)
  // -------------------------------------------------------------------------

  log(`Catching up from block ${lastBlock.current}...`);

  try {
    const swapEvents = await contractA.queryFilter(
      contractA.filters.SwapLocked(), lastBlock.current, "latest"
    );
    if (swapEvents.length) log(`Processing ${swapEvents.length} historical SwapLocked event(s)...`);
    for (const ev of swapEvents) {
      await handleSwapLocked(contractB, processed, ev.args[0], ev.args[1], ev.transactionHash);
      lastBlock.current = Math.max(lastBlock.current, ev.blockNumber);
    }
  } catch (e) {
    err("Error during SwapLocked catch-up:", e.message);
  }

  try {
    const withdrawEvents = await contractA.queryFilter(
      contractA.filters.Withdraw(), lastBlock.current, "latest"
    );
    if (withdrawEvents.length) log(`Processing ${withdrawEvents.length} historical Withdraw event(s)...`);
    for (const ev of withdrawEvents) {
      await handleWithdraw(contractB, processed, ev.args[0], ev.args[1], ev.transactionHash);
      lastBlock.current = Math.max(lastBlock.current, ev.blockNumber);
    }
  } catch (e) {
    err("Error during Withdraw catch-up:", e.message);
  }

  // Advance lastBlock to the current chain head so the poll loop starts from now
  try {
    const head = await providerA.getBlockNumber();
    lastBlock.current = Math.max(lastBlock.current, head);
  } catch (_) {}

  saveState(processed, lastBlock.current);
  log(`Catch-up complete. Polling every ${POLL_INTERVAL_MS}ms for new events...`);

  // -------------------------------------------------------------------------
  // Poll loop
  // -------------------------------------------------------------------------

  const timer = setInterval(
    () => poll(contractA, contractB, processed, lastBlock).catch((e) => err("Poll error:", e.message)),
    POLL_INTERVAL_MS
  );

  // -------------------------------------------------------------------------
  // Graceful shutdown
  // -------------------------------------------------------------------------

  function shutdown() {
    log("Shutting down relayer...");
    clearInterval(timer);
    saveState(processed, lastBlock.current);
    process.exit(0);
  }

  process.on("SIGINT",  shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((e) => {
  err("Fatal:", e);
  process.exit(1);
});
