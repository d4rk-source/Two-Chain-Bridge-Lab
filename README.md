## Bridge_ctf — Two-chain local bridge demo (Foundry + offchain relayer)

This repository demonstrates a lightweight two-chain bridge flow for local testing with Foundry and Anvil. It includes two Solidity contracts (one on "Chain A" to lock ETH and emit events, and one on "Chain B" as a WETH-like ERC20), Foundry deploy scripts, and an offchain relayer (Node.js) that listens to events on Chain A and performs corresponding actions on Chain B.

This is intended as a small CTF / dev playground: not production-ready, but useful for experimenting with relayer logic, event handling, and local multi-node workflows.

**Contents**

- `src/chain A/LockAndSwap.sol`: Lock ETH, record per-address deposits, emit `SwapLocked(address sender, uint256 amount)` and `Withdraw(address account, uint256 amount)`. Supports user withdraws and owner withdraws.
- `src/Chain B/WETH.sol`: Minimal ERC20 (OpenZeppelin) with privileged `bridge(address to, uint256 amount)` mint and an owner `burn(address from, uint256 amount)` for mirror withdrawals.
- `script/DeployLockAndSwap.s.sol`, `script/DeployWETH.s.sol`: Forge scripts to deploy the contracts to a local node.
- `offchain/relayer.js`: Node.js relayer that listens for `SwapLocked` and `Withdraw` events on Chain A and calls `bridge(...)` (mint) or `burn(...)` on Chain B respectively. Includes historical catch-up and simple processed-tx persistence to avoid duplicates.
- `offchain/bridge.js`, `offchain/bridge.py`: small offchain helpers used during development (call single contract functions, etc.).
- `offchain/run-local-relay.sh`: helper script to start two Anvil instances, deploy both contracts via `forge script --broadcast`, and start the relayer in background; writes logs to `offchain/logs/`.

**High-level flow**

- A user sends ETH to `LockAndSwap.lockAndSwap()` (or `receive()`), which increases `deposits[user]` and emits `SwapLocked(user, amount)`.
- The relayer listens for `SwapLocked` events on Chain A and calls `WETH.bridge(user, amount)` on Chain B to mint equivalent tokens.
- When a user withdraws (or an owner withdraws on their behalf) and `LockAndSwap` emits `Withdraw(account, amount)`, the relayer calls `WETH.burn(account, amount)` on Chain B to burn mirrored tokens.

Important notes:

- `WETH.burn(...)` in this repo is `onlyOwner`. The relayer must use a private key that controls the owner account on Chain B, or you must adapt permissions (e.g., add a bridge-only burn or grant the relayer the `owner` role) for `burn` to succeed.
- The repo persists processed transaction hashes in `offchain/relayer_state.json` to avoid reprocessing events. This is a simple file-based approach for local testing.

Getting started (local)

1. Install Foundry (if not installed): follow https://book.getfoundry.sh/
2. Install OpenZeppelin contracts (if not already in `lib/`):

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

3. Build the contracts:

```bash
forge build
```

4. Use the provided helper to start two local Anvil nodes, deploy contracts, and run the relayer:

```bash
chmod +x offchain/run-local-relay.sh
./offchain/run-local-relay.sh
```

The script will:

- start two Anvil instances (Chain A on `http://127.0.0.1:8545` and Chain B on `http://127.0.0.1:8546` by default)
- deploy `LockAndSwap` to Chain A and `WETH` to Chain B
- start the relayer (`node offchain/relayer.js`) in the background and write logs to `offchain/logs/`

Environment variables used by the relayer (when running manually):

Note: the relayer will try to load a `.env` file using the `dotenv` package if it is installed, but this is optional — you can also pass env vars inline or via your shell. To use a `.env` file, install `dotenv` in your project:

```bash
npm install dotenv
# or
yarn add dotenv
```

```bash
CHAIN_A_RPC=http://127.0.0.1:8545
CHAIN_B_RPC=http://127.0.0.1:8546
CHAIN_A_CONTRACT=<LockAndSwap address>
CHAIN_B_CONTRACT=<WETH address>
PRIVATE_KEY_B=<private key that is owner on Chain B>
RELAYER_STATE_FILE=offchain/relayer_state.json
```

Developer tips & troubleshooting

- If the relayer appears to "miss" events, it will still perform a historical catch-up on startup by `queryFilter`ing events from block 0. For production you should track and persist a last-processed block instead of starting at 0.
- Ensure the relayer's `PRIVATE_KEY_B` controls the `owner` on Chain B (or change `WETH` privileges) so `burn(...)` can be called. Alternatively change `WETH` to make `burn` callable by a `bridge` role.
- Logs from automation are in `offchain/logs/` (deploy logs, relayer logs, and `relayer_state.json`). If the run script exits early, inspect those logs.

Next improvements you might want to add

- Integration tests that run the full flow (emit `SwapLocked`, verify mint on Chain B, emit `Withdraw`, verify burn on Chain B).
- A stronger persistence store for relayer state (SQLite / LevelDB / Postgres) and concurrency controls.
- Confirmation handling (wait for N confirmations before relaying) and retry/backoff for failed relayed transactions.
- Add `reentrancy` guards and input validation on contracts for production scenarios.

License: see repository `LICENSE`.

If you want, I can also:

- Add a short integration test harness (Forge + Node) that demonstrates one end-to-end swap and withdraw.
- Make the relayer read configuration from an `.env` file and support CLI flags.

---

Minimal Foundry usage reminders

```bash
forge build      # compile
forge test       # run tests
anvil            # run a single Anvil node
```

For more Foundry docs: https://book.getfoundry.sh/
