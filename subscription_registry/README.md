# SubscriptionRegistry

An [Arbitrum Stylus](https://docs.arbitrum.io/stylus/stylus-gentle-introduction)
(Rust → WASM) contract for Fangorn's **paid storage subscription**. It is deliberately
separate from the [`DataRegistry`](../data_registry) — the registry owns publisher
registration + the state-root timeline; this contract owns only "has this wallet paid
for storage recently." The two are wired together by a cross-contract call (below).

## How it works

1. A registered publisher calls **`subscribe()`** (paying a USDC fee).
2. The contract first cross-calls `DataRegistry.isRegistered(caller)` and reverts
   `NotRegistered` if the caller isn't an active publisher.
3. It then pulls the fee in USDC via `transferFrom` (the caller must `approve` this
   contract first) and stamps `subscribed_at[caller] = block.timestamp`.
4. The off-chain upload gate (the `pinata-url-provider` worker) reads
   **`access(addr)`** to decide whether to serve an upload.

The **active window** (e.g. 30 days) is **not** enforced on-chain — the contract only
records *when* the fee was last paid. The worker compares `paidAt` against its
configurable `SUBSCRIPTION_WINDOW_DAYS`, so the window is tunable without redeploying
the contract. `subscribe()` is callable while already active; a renewal just re-stamps
`now`.

## The `access` view — one read for the gate

```solidity
function access(address publisher) external view returns (bool registered, uint64 paidAt);
```

`registered` is a cross-contract call to `DataRegistry.isRegistered(publisher)`; `paidAt`
is that publisher's last subscription timestamp (0 if never). So a single `eth_call`
gives the worker both the registration gate and the subscription-window input — the
worker never has to call the DataRegistry directly.

## State

| Field | Type | Meaning |
|-------|------|---------|
| `admin` | `address` | Protocol admin (fees, token, withdrawals). |
| `usdc` | `address` | ERC-20 the fee is paid in (USDC). |
| `data_registry` | `address` | The DataRegistry queried for `isRegistered`. |
| `subscription_fee` | `uint256` | Fee in **USDC base units (6 decimals)** — `1 USDC = 1_000_000`. |
| `subscribed_at` | `address → uint64` | Unix-seconds of each publisher's last payment. |

## Interface

Stylus exposes Rust `snake_case` as `camelCase` in the ABI (`abi.json`) — calling the
snake_case selector reverts.

| Rust | ABI selector | Mutability | Notes |
|------|--------------|------------|-------|
| `init(admin, usdc, data_registry, subscription_fee)` | constructor | — | Deploy-time only. |
| `subscribe()` | `subscribe()` | nonpayable | Requires registration; pulls USDC; stamps `now`. |
| `access(publisher)` | `access(address)` | view | `(registered, paidAt)` — the worker's oracle. |
| `subscribed_at(publisher)` | `subscribedAt(address)` | view | `uint64` timestamp, 0 if never. |
| `subscription_fee()` | `subscriptionFee()` | view | `uint256` (USDC base units). |
| `usdc()` | `usdc()` | view | Fee token address. |
| `data_registry()` | `dataRegistry()` | view | Registry it checks against. |
| `admin()` | `admin()` | view | Admin address. |
| `set_subscription_fee(fee)` | `setSubscriptionFee(uint256)` | admin | |
| `set_usdc(token)` | `setUsdc(address)` | admin | |
| `set_data_registry(registry)` | `setDataRegistry(address)` | admin | |
| `withdraw_usdc(to, amount)` | `withdrawUsdc(address,uint256)` | admin | Sweep collected USDC. |
| `withdraw_eth(to, amount)` | `withdrawEth(address,uint256)` | admin | Rescue native ETH. |

**Errors:** `Unauthorized`, `NotRegistered`, `SubscriptionFeeRequired`, `TransferFailed`.
**Events:** `Subscribed(address indexed publisher, uint64 paid_at)`,
`SubscriptionFeeChanged(uint256 fee)`.

**Cross-contract interfaces** (`sol_interface!`): `IERC20 { transferFrom, transfer }`
for the fee/treasury, and `IDataRegistry { isRegistered(address) view returns (bool) }`
for the registration check.

## Fees & USDC

- Fees are in **USDC base units (6 decimals)**. `subscribe()` and the withdrawals move
  USDC via `transferFrom`/`transfer`; a call that reverts or returns `false` maps to
  `SubscriptionFeeRequired` / `TransferFailed` and changes no state.
- The caller **must `approve`** this contract for at least the fee before `subscribe()`.
  The website's subscription library does this automatically (allowance check → approve
  → subscribe).

## Consumers

- **Worker** (`../../webworker/pinata-url-provider`) — reads `access(addr)` to gate
  uploads past the free tier (`SUBSCRIPTION_CONTRACT_ADDRESS` / `ACCESS_FUNCTION`).
- **Website** (`../../websites/fangorn`) — `src/subscription.js` reads
  `subscribedAt`/`subscriptionFee` and drives the approve → `subscribe()` flow with the
  user's wallet (`VITE_SUBSCRIPTION_ADDRESS`).

## Build / test / deploy

Standalone crate (the `contracts/` dir is **not** a Cargo workspace).

```bash
cargo test                              # unit tests use stylus-sdk TestVM
cargo stylus export-abi --json          # regenerate abi.json
cargo stylus check                      # validate the WASM is deployable
```

Deploy with the repo script (prompts for which contract(s) to deploy):

```bash
../deploy.sh                            # both, or just this one
```

Deploying **only** this contract needs the address of an already-deployed DataRegistry
to check registration against (`../deploy.sh` prompts for it, or preset
`DATA_REGISTRY_ADDR`). Constructor:
`init(admin, usdc, data_registry, subscription_fee)` — fees in USDC base units.

After deploying, point the consumers at the new address: `wrangler.toml`
`SUBSCRIPTION_CONTRACT_ADDRESS` and `websites/fangorn/.env.local`
`VITE_SUBSCRIPTION_ADDRESS`.

## Testing note

The unit tests mock the two external calls with `TestVM`: `mock_call` for the USDC
`transferFrom`/`transfer`, and `mock_static_call` for `DataRegistry.isRegistered`.
Because TestVM returns one shared value per transaction, a single test can't make the
two cross-calls return *different* bools — so the "registered but USDC transfer fails"
branch isn't unit-tested here; that exact mapping is covered by `data_registry`'s
`test_registration_fails_when_usdc_transfer_fails` (identical `pull_usdc` code).
