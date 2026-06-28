#!/usr/bin/env bash
# run-local-relay.sh
#
# Spins up two local Anvil chains, deploys both contracts, and starts the relayer.
# Intended for local dev and demo only — uses well-known Anvil test keys.
#
# Usage:
#   chmod +x offchain/run-local-relay.sh
#   ./offchain/run-local-relay.sh
#
# Logs land in offchain/logs/. PIDs are printed at the end so you can
# kill everything with:  kill <PID_A> <PID_B> <PID_RELAYER>

set -euo pipefail

# -------------------------------------------------------------------------
# Config
# -------------------------------------------------------------------------

MNEMONIC='test test test test test test test test test test test junk'
ANVIL_A_PORT=8545
ANVIL_B_PORT=8546
ANVIL_A_RPC="http://127.0.0.1:${ANVIL_A_PORT}"
ANVIL_B_RPC="http://127.0.0.1:${ANVIL_B_PORT}"

LOG_DIR='offchain/logs'
ANVIL_A_LOG="${LOG_DIR}/anvilA.log"
ANVIL_B_LOG="${LOG_DIR}/anvilB.log"
DEPLOY_A_LOG="${LOG_DIR}/deploy_lockandswap.log"
DEPLOY_B_LOG="${LOG_DIR}/deploy_weth.log"
RELAYER_LOG="${LOG_DIR}/relayer.log"
STATE_FILE="${LOG_DIR}/relayer_state.json"

# Well-known Anvil dev key — never use in production
PK='0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'

# -------------------------------------------------------------------------
# Setup
# -------------------------------------------------------------------------

mkdir -p "$LOG_DIR"
[ -f "$STATE_FILE" ] || echo "[]" > "$STATE_FILE"

# Kill any leftover Anvil processes on our ports before starting
pkill -f "anvil.*${ANVIL_A_PORT}" 2>/dev/null || true
pkill -f "anvil.*${ANVIL_B_PORT}" 2>/dev/null || true

# -------------------------------------------------------------------------
# Start Anvil nodes
# -------------------------------------------------------------------------

echo "Starting Anvil A on port ${ANVIL_A_PORT}..."
nohup anvil --mnemonic "$MNEMONIC" --port "$ANVIL_A_PORT" > "$ANVIL_A_LOG" 2>&1 &
PID_ANVIL_A=$!
disown $PID_ANVIL_A

echo "Starting Anvil B on port ${ANVIL_B_PORT}..."
nohup anvil --mnemonic "$MNEMONIC" --port "$ANVIL_B_PORT" > "$ANVIL_B_LOG" 2>&1 &
PID_ANVIL_B=$!
disown $PID_ANVIL_B

# Wait until both nodes are accepting connections
echo "Waiting for Anvil nodes to come up..."
for rpc in "$ANVIL_A_RPC" "$ANVIL_B_RPC"; do
  for _ in $(seq 1 20); do
    curl -sf -X POST "$rpc" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      > /dev/null 2>&1 && break
    sleep 0.25
  done
done
echo "Both Anvil nodes ready."

# -------------------------------------------------------------------------
# Deploy contracts
# -------------------------------------------------------------------------

echo "Deploying LockAndSwap to Chain A (${ANVIL_A_RPC})..."
forge script script/DeployLockAndSwap.s.sol:DeployLockAndSwap \
  --rpc-url "$ANVIL_A_RPC" --private-key "$PK" --broadcast 2>&1 | tee "$DEPLOY_A_LOG"

LOCK_ADDR=$(grep -Eo "0x[0-9a-fA-F]{40}" "$DEPLOY_A_LOG" | head -n1 || true)
if [ -z "$LOCK_ADDR" ]; then
  echo "ERROR: Could not find LockAndSwap address in ${DEPLOY_A_LOG}" >&2
  exit 1
fi
echo "LockAndSwap deployed at ${LOCK_ADDR}"

echo "Deploying WETH to Chain B (${ANVIL_B_RPC})..."
forge script script/DeployWETH.s.sol:DeployWETH \
  --rpc-url "$ANVIL_B_RPC" --private-key "$PK" --broadcast 2>&1 | tee "$DEPLOY_B_LOG"

WETH_ADDR=$(grep -Eo "0x[0-9a-fA-F]{40}" "$DEPLOY_B_LOG" | head -n1 || true)
if [ -z "$WETH_ADDR" ]; then
  echo "ERROR: Could not find WETH address in ${DEPLOY_B_LOG}" >&2
  exit 1
fi
echo "WETH deployed at ${WETH_ADDR}"

# -------------------------------------------------------------------------
# Start relayer
# -------------------------------------------------------------------------

echo "Starting relayer..."
CHAIN_A_RPC="$ANVIL_A_RPC" \
CHAIN_B_RPC="$ANVIL_B_RPC" \
CHAIN_A_CONTRACT="$LOCK_ADDR" \
CHAIN_B_CONTRACT="$WETH_ADDR" \
PRIVATE_KEY_B="$PK" \
RELAYER_STATE_FILE="$STATE_FILE" \
  nohup node offchain/relayer.js > "$RELAYER_LOG" 2>&1 &
PID_RELAYER=$!
disown $PID_RELAYER

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------

echo ""
echo "All processes running:"
echo "  Anvil A    pid=${PID_ANVIL_A}   logs=${ANVIL_A_LOG}"
echo "  Anvil B    pid=${PID_ANVIL_B}   logs=${ANVIL_B_LOG}"
echo "  Relayer    pid=${PID_RELAYER}   logs=${RELAYER_LOG}"
echo ""
echo "Contracts:"
echo "  LockAndSwap (Chain A): ${LOCK_ADDR}"
echo "  WETH        (Chain B): ${WETH_ADDR}"
echo ""
echo "To stop everything:  kill ${PID_ANVIL_A} ${PID_ANVIL_B} ${PID_RELAYER}"
