# Two-Chain Bridge Lab

A minimal local bridge demo using **Foundry + Anvil + a Node.js relayer**.
This project shows how two separate chains can communicate through an off-chain relayer by watching events on Chain A and performing actions on Chain B.

Not production-ready — this is a personal learning lab for experimenting with cross-chain flows, relayer logic, and multi-node setups.

---

## Overview

The setup includes:

- **Chain A — LockAndSwap**

  - Accepts ETH deposits
  - Tracks per-user balances
  - Emits:

    - `SwapLocked(address sender, uint256 amount)`
    - `Withdraw(address account, uint256 amount)`

- **Chain B — WETH-like ERC20**

  - `bridge(to, amount)` — mints tokens
  - `burn(from, amount)` — burns tokens
  - Uses OpenZeppelin ERC20

- **Relayer (Node.js)**

  - Listens to Chain A for `SwapLocked` and `Withdraw`
  - Calls `bridge(...)` or `burn(...)` on Chain B
  - Keeps a small JSON file of processed tx hashes to avoid duplicates

---

## Repo Layout

```
src/
  ChainA/LockAndSwap.sol
  ChainB/WETH.sol
script/
  DeployLockAndSwap.s.sol
  DeployWETH.s.sol
offchain/
  relayer.js
  bridge.js
  bridge.py
  run-local-relay.sh
  logs/
```

---

## Flow Summary

1. User sends ETH to Chain A → emits `SwapLocked`.
2. Relayer sees the event → mints equivalent tokens on Chain B with `bridge(...)`.
3. User withdraws on Chain A → emits `Withdraw`.
4. Relayer sees it → burns tokens on Chain B with `burn(...)`.

---

## Important Notes

- `WETH.burn()` is `onlyOwner`.
  Your relayer’s private key **must** be the owner on Chain B unless you adjust permissions or add a bridge role.
- Processed tx hashes are stored in `offchain/relayer_state.json`. This is fine for local testing.

---

## Getting Started (Local)

### 1. Install Foundry

[https://book.getfoundry.sh/](https://book.getfoundry.sh/)

### 2. Install OpenZeppelin

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

### 3. Build

```bash
forge build
```

### 4. Run the full setup

```bash
chmod +x offchain/run-local-relay.sh
./offchain/run-local-relay.sh
```

This script will:

- start **two** Anvil instances (A: `8545`, B: `8546`)
- deploy LockAndSwap + WETH
- start the relayer (`node offchain/relayer.js`)
- write logs into `offchain/logs/`

---

## Running the Relayer Manually

Environment variables:

```
CHAIN_A_RPC=http://127.0.0.1:8545
CHAIN_B_RPC=http://127.0.0.1:8546
CHAIN_A_CONTRACT=<LockAndSwap address>
CHAIN_B_CONTRACT=<WETH address>
PRIVATE_KEY_B=<owner private key for Chain B>
RELAYER_STATE_FILE=offchain/relayer_state.json
```

If you want `.env` support:

```bash
npm install dotenv
```

---

## Troubleshooting

- If events seem “missed,” the relayer still catches up by querying from block 0.
  For real use, track last-processed block instead.
- If `burn()` fails, your relayer key is not the owner. Adjust permissions or roles.
- Check `offchain/logs/` for deploy logs, relayer logs, and the state file.

---
