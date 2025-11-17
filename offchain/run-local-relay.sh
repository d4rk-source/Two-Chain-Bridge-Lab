#!/usr/bin/env bash
set -euo pipefail
# Starts two local Anvil nodes, deploys LockAndSwap on chain A and WETH on chain B,
# then starts the relayer in background.

# Configuration
MNEMONIC='test test test test test test test test test test test junk'
ANVIL_A_RPC='http://127.0.0.1:8545'
ANVIL_B_RPC='http://127.0.0.1:8546'
ANVIL_A_LOG='offchain/logs/anvilA.log'
ANVIL_B_LOG='offchain/logs/anvilB.log'
DEPLOY_A_LOG='offchain/logs/deploy_lockandswap.log'
DEPLOY_B_LOG='offchain/logs/deploy_weth.log'
RELAYER_LOG='offchain/logs/relayer.log'
STATE_FILE='offchain/logs/relayer_state.json'

# Private key to use for deployments and relayer (as requested)
PK='0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'

echo "Starting local Anvil nodes..."

# Start Anvil for Chain A (default port 8545)
nohup anvil --mnemonic "$MNEMONIC" > "$ANVIL_A_LOG" 2>&1 &
PID_ANVIL_A=$!
disown $PID_ANVIL_A
echo "Anvil A started (pid=$PID_ANVIL_A), logs: $ANVIL_A_LOG"

# Start Anvil for Chain B on port 8546
nohup anvil --mnemonic "$MNEMONIC" -p 8546 > "$ANVIL_B_LOG" 2>&1 &
PID_ANVIL_B=$!
disown $PID_ANVIL_B
echo "Anvil B started (pid=$PID_ANVIL_B), logs: $ANVIL_B_LOG"

# wait for Anvil to start
sleep 0.5

# Deploy LockAndSwap on Chain A
echo "Deploying LockAndSwap to $ANVIL_A_RPC (logs -> $DEPLOY_A_LOG)"
set -x
forge script script/DeployLockAndSwap.s.sol:DeployLockAndSwap \
  --rpc-url "$ANVIL_A_RPC" --private-key "$PK" --broadcast 2>&1 | tee "$DEPLOY_A_LOG"
set +x

# Extract deployed address from log
LOCK_ADDR=$(grep -Eo "0x[0-9a-fA-F]{40}" "$DEPLOY_A_LOG" | head -n1 || true)
if [ -z "$LOCK_ADDR" ]; then
  echo "Failed to find LockAndSwap deployed address in $DEPLOY_A_LOG"
  echo "Deploy log:"; sed -n '1,200p' "$DEPLOY_A_LOG"
  exit 1
fi
echo "LockAndSwap deployed at $LOCK_ADDR"

# Deploy WETH on Chain B
echo "Deploying WETH to $ANVIL_B_RPC (logs -> $DEPLOY_B_LOG)"
set -x
forge script script/DeployWETH.s.sol:DeployWETH \
  --rpc-url "$ANVIL_B_RPC" --private-key "$PK" --broadcast 2>&1 | tee "$DEPLOY_B_LOG"
set +x

WETH_ADDR=$(grep -Eo "0x[0-9a-fA-F]{40}" "$DEPLOY_B_LOG" | head -n1 || true)
if [ -z "$WETH_ADDR" ]; then
  echo "Failed to find WETH deployed address in $DEPLOY_B_LOG"
  echo "Deploy log:"; sed -n '1,200p' "$DEPLOY_B_LOG"
  exit 1
fi
echo "WETH deployed at $WETH_ADDR"

# Ensure relayer state exists
mkdir -p offchain
if [ ! -f "$STATE_FILE" ]; then
  echo "[]" > "$STATE_FILE"
fi

echo "Starting relayer (background). Logs -> $RELAYER_LOG"
CHINA_A_RPC_ENV="$ANVIL_A_RPC" CHAIN_A_RPC="$ANVIL_A_RPC" \
CHAIN_B_RPC="$ANVIL_B_RPC" CHAIN_A_CONTRACT="$LOCK_ADDR" \
CHAIN_B_CONTRACT="$WETH_ADDR" PRIVATE_KEY_B="$PK" \
  nohup node offchain/relayer.js > "$RELAYER_LOG" 2>&1 &
RELAYER_PID=$!
disown $RELAYER_PID

echo "Relayer started (pid=$RELAYER_PID)."
echo "All processes started. You can check logs in the offchain/ directory."

echo "To stop processes you started, use:"
echo "  kill $PID_ANVIL_A $PID_ANVIL_B $RELAYER_PID"
