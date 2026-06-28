# Two-Chain Bridge — Homelab Project

A local cross-chain bridge built from scratch to practice smart contract development, event-driven off-chain architecture, and the Foundry toolchain. Two independent EVM chains communicate through an event-listening relayer: lock ETH on Chain A, receive a wrapped token on Chain B. Withdraw on Chain A, tokens are burned on Chain B.

**Stack:** Solidity 0.8.20 · Foundry · Anvil · Node.js (ethers v6) · OpenZeppelin

---

## Architecture

```
┌──────────────────────────────────┐        ┌──────────────────────────────────┐
│           CHAIN A (Anvil :8545)  │        │          CHAIN B (Anvil :8546)   │
│                                  │        │                                  │
│  LockAndSwap.sol                 │        │  WETH.sol  (ERC20)               │
│  ┌─────────────────────────┐     │        │  ┌─────────────────────────┐     │
│  │ lockAndSwap() payable   │     │        │  │ bridge(to, amount)      │     │
│  │ withdraw(amount)        │     │        │  │   → _mint               │     │
│  │ emergencyWithdraw(...)  │     │        │  │ burn(from, amount)      │     │
│  │ deposits[addr]          │     │        │  │   → _burn               │     │
│  └────────────┬────────────┘     │        │  └────────────▲────────────┘     │
│               │ events           │        │               │ calls            │
└───────────────┼──────────────────┘        └───────────────┼──────────────────┘
                │                                           │
                │  ┌────────────────────────────────────┐   │
                └──►       relayer.js (Node.js)         ├───┘
                   │                                    │
                   │  - listens: SwapLocked → bridge()  │
                   │  - listens: Withdraw   → burn()    │
                   │  - dedup via tx hash set           │
                   │  - catch-up from saved block       │
                   │  - retry with exponential backoff  │
                   └────────────────────────────────────┘
```

### Flow

| Step | Action                              | Chain A                       | Relayer       | Chain B                                   |
| ---- | ----------------------------------- | ----------------------------- | ------------- | ----------------------------------------- |
| 1    | User calls `lockAndSwap()` with ETH | emits `SwapLocked`            | detects event | calls `bridge(user, amount)` → mints WETH |
| 2    | User calls `withdraw(amount)`       | emits `Withdraw`, returns ETH | detects event | calls `burn(user, amount)` → burns WETH   |

---

## Contracts

### `LockAndSwap.sol` (Chain A)

| Symbol                                | Description                                  |
| ------------------------------------- | -------------------------------------------- |
| `lockAndSwap() payable`               | Lock ETH and emit `SwapLocked`               |
| `receive() payable`                   | Fallback — same effect as `lockAndSwap()`    |
| `withdraw(uint256)`                   | Return depositor's own ETH; emits `Withdraw` |
| `emergencyWithdraw(address, uint256)` | Owner-only emergency drain                   |
| `setOwner(address)`                   | Transfer ownership                           |
| `deposits[addr]`                      | Per-address deposit tracking                 |
| `totalLocked`                         | Sum of all tracked ETH in contract           |

Notable practices:

- `ReentrancyGuard` on all ETH-sending paths (belt-and-suspenders on top of CEI)
- Custom errors (`ZeroValue`, `NotOwner`, etc.) instead of revert strings — lower gas, cleaner ABI
- `OwnershipTransferred` event mirrors the OZ Ownable convention
- Internal `_lock()` helper keeps `lockAndSwap()` and `receive()` DRY

### `WETH.sol` (Chain B)

Extends OpenZeppelin `ERC20` + `Ownable`. Minted and burned exclusively by the bridge relayer.

| Symbol                     | Description                       |
| -------------------------- | --------------------------------- |
| `bridge(address, uint256)` | Mint tokens — `onlyBridge`        |
| `burn(address, uint256)`   | Burn tokens — `onlyBridge`        |
| `setBridge(address)`       | Owner updates the relayer address |

Both `bridge()` and `burn()` are restricted to `bridgeAddress` (the relayer), keeping the permission model symmetric. The owner (deployer) manages the bridge address but cannot mint or burn directly after `setBridge` is called.

---

## Tests

43 Foundry tests covering unit behaviour, access control, edge cases, and fuzz cases.

```
test/LockAndSwap.t.sol   27 tests
test/WETH.t.sol          16 tests
```

```bash
forge test
```

```
Ran 43 tests: 43 passed, 0 failed
```

Test highlights:

- **Fuzz** — `testFuzz_lockAndSwap_tracksDeposit(uint96)` and `testFuzz_withdraw_partialAmount(uint96,uint96)` run 256 randomised inputs each
- **Access control** — every `onlyOwner` / `onlyBridge` path has a negative test
- **State invariants** — `totalLocked`, `deposits[addr]`, and contract balance are checked together after each operation
- **Event assertions** — `vm.expectEmit` verifies every event emission

---

## Relayer (`offchain/relayer.js`)

- Listens for `SwapLocked` and `Withdraw` events on Chain A using ethers v6
- Calls `bridge()` / `burn()` on Chain B via a configured wallet
- **Deduplication:** processed tx hashes are saved to a JSON state file — safe to restart
- **Catch-up:** on startup, queries all historical events from the last saved block
- **Retry:** failed transactions are retried up to 3 times with exponential backoff
- **Graceful shutdown:** `SIGINT` / `SIGTERM` flush state before exit

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `anvil`, `cast`)
- Node.js ≥ 18
- OpenZeppelin contracts (installed once below)

### 1 — Install dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts
cd offchain && npm install && cd ..
```

### 2 — Build and test

```bash
forge build
forge test
```

### 3 — Run the full local setup

```bash
chmod +x offchain/run-local-relay.sh
./offchain/run-local-relay.sh
```

This script will:

1. Start two Anvil nodes (Chain A on `:8545`, Chain B on `:8546`)
2. Deploy `LockAndSwap` and `WETH` using the default Anvil dev key
3. Start the relayer in the background
4. Print all PIDs and contract addresses

Logs land in `offchain/logs/`.

### 4 — Try it manually

After the setup script runs, grab the deployed addresses from its output and use `cast` to interact:

```bash
# Lock 0.1 ETH on Chain A (triggers mint on Chain B)
cast send <LOCK_AND_SWAP_ADDR> "lockAndSwap()" \
  --value 0.1ether \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://127.0.0.1:8545

# Check WETH balance on Chain B
cast call <WETH_ADDR> "balanceOf(address)(uint256)" <YOUR_ADDRESS> \
  --rpc-url http://127.0.0.1:8546
```

---

## Relayer — Manual Configuration

```bash
CHAIN_A_RPC=http://127.0.0.1:8545 \
CHAIN_B_RPC=http://127.0.0.1:8546 \
CHAIN_A_CONTRACT=<LockAndSwap address> \
CHAIN_B_CONTRACT=<WETH address> \
PRIVATE_KEY_B=<relayer private key> \
node offchain/relayer.js
```

The relayer's key must be the `bridgeAddress` on the WETH contract. The `run-local-relay.sh` script handles this automatically.

---

## Project Layout

```
src/
  chainA/LockAndSwap.sol    Chain A — ETH lock/unlock
  chainB/WETH.sol           Chain B — ERC20 bridge token
script/
  DeployLockAndSwap.s.sol
  DeployWETH.s.sol
test/
  LockAndSwap.t.sol         27 unit + fuzz tests
  WETH.t.sol                16 unit + fuzz tests
offchain/
  relayer.js                Off-chain event relayer
  run-local-relay.sh        One-command local demo
  package.json
  logs/                     Runtime logs (gitignored)
```

---

## What This Is Not

This is a **homelab / learning project**, not a production bridge. Notable omissions:

- No finality waiting — the relayer acts on the first confirmation
- No challenge/fraud-proof mechanism
- No fee model
- Single relayer = single point of failure
- `emergencyWithdraw` does not update per-user deposit records (documented intentionally)
