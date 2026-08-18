# Fangorn contracts

Three independent Stylus (Rust → WASM) contracts on Arbitrum Sepolia. **No proxies,
no factories, no delegatecall** — each contract is deployed directly and owns one
concern. Where two need to talk, they do it with a plain cross-contract call to a
stored address, not through a shared storage layout.

Almost nothing lives on-chain. A publisher's whole knowledge graph is one `bytes32`
in the DataRegistry — the sha256 digest of their latest commit block. The graph
itself is content-addressed IPLD off-chain (IPFS/Pinata); the chain is the trusted
pointer and the lock that keeps the timeline linear.

## Architecture

```
                  register()              commitStateRoot(old, new)
  Publisher ─────────────────────▶  DataRegistry  ◀────────────────────── Publisher
  (wallet)                          (Stylus)                              (wallet)
                                     │  address → bytes32          emits StateCommitted
                                     │  (one head per publisher)          │
                                     │                                    ▼
                                     │ isRegistered(addr)          SDK light-client
                                     │  ▲   (static cross-call)   (watches logs, no indexer)
                                     │  │
    subscribe()                      │  │
  Publisher ──────────────▶  SubscriptionRegistry
  (wallet, USDC)                     (Stylus)
                                      │  address → subscribed_at
                                      │
                                      │  access(addr) → (registered, paidAt)
                                      ▼
                              Upload gate (Cloudflare Worker)
                              one eth_call = both answers


  SettlementRegistry (Stylus, standalone) ──▶ Semaphore   ──▶ anonymous paid access
  resource pricing + USDC payment + nullifiers                (not wired to the above)
```

The DataRegistry has no idea the SubscriptionRegistry exists; the arrow points one
way. Swapping either side is a redeploy plus a `setDataRegistry` call, not a
migration.

## Layout

| Path                     | Contract             | Toolchain    | Deployed by      |
|--------------------------|----------------------|--------------|------------------|
| `data_registry/`         | DataRegistry         | cargo stylus | `deploy.sh`      |
| `subscription_registry/` | SubscriptionRegistry | cargo stylus | `deploy.sh`      |
| `settlement_registry/`   | SettlementRegistry   | cargo stylus | by hand (README) |

## DataRegistry

Publisher registration and the state-root timeline. Every publisher and every reader
talks to this contract; the other two are optional.

State: `admin`, `registration_fee`, `statuses` (0 unregistered / 1 active /
2 suspended), `publisher_count`, `namespace_heads` (`address → bytes32`).

- `register()` — payable; pays the registration fee to become active. Re-registering
  a suspended account reactivates it and preserves its historic root.
- `commit_state_root(old_root, new_root)` — the only graph-mutating route.
  Compare-and-swap: rejects unless the caller is active **and** `old_root` equals the
  stored head (`StaleStateRoot`). That CAS is what enforces a linear timeline. Emits
  `StateCommitted(publisher, old_root, new_root)`, the single event the SDK's
  light-client watches.
- Views: `get_namespace_head`, `is_registered`, `get_publisher_status`,
  `publisher_count`, `registration_fee`, `admin`.
- Admin: `suspend_publisher`, `set_registration_fee`.
- `init(admin, registration_fee)`.

`namespace_heads` is per-**publisher**, not per-namespace: one root each, with
namespaces as keys inside the off-chain root map it points at.

The registration fee is paid in the native token. Note that `deploy.sh` passes a USDC
address as a third constructor argument, which this contract does not take — fix one
side before deploying it.

`commit_state_root` does not verify that `new_root` is a well-formed commit; it only
checks the CAS. The contract is deliberately structure-agnostic — it moves a
`bytes32`, and the SDK defines what that value means. Proving the root is on the
roadmap (`TODO: needs a merkle proof` in the source).

## SubscriptionRegistry

The paid storage subscription, kept separate so the registry is never concerned about
billing. Fees are **USDC** (6-decimal base units).

State: `admin`, `usdc`, `data_registry`, `subscription_fee`, `subscribed_at`
(`address → Unix seconds`).

- `subscribe()` — not payable. Cross-calls `IDataRegistry.isRegistered(caller)` and
  reverts `NotRegistered` if the caller isn't a publisher, then pulls the fee via
  `IERC20::transferFrom` (**approve this contract first**), stamps
  `subscribed_at = now`, emits `Subscribed`. Renewing just re-stamps `now`.
- `access(addr) → (bool registered, uint64 paidAt)` — the upload gate's single
  oracle: registration and last payment in one `eth_call`.
- Views: `subscribed_at`, `subscription_fee`, `usdc`, `data_registry`, `admin`.
- Admin: `set_subscription_fee`, `set_usdc`, `set_data_registry`, `withdraw_usdc`,
  `withdraw_eth`. `init(admin, usdc, data_registry, subscription_fee)`.

**This contract is only relevant if you use Fangorn's hosted storage.** The
subscription pays for presigned upload URLs from the Worker, and the Worker is the only
thing that reads `access`. Publishers who bring their own Pinata JWT upload straight
to Pinata, never touch the Worker, and therefore never touch this contract — they
still `register` in the DataRegistry and `commitStateRoot` as normal, since publishing
on-chain is gated by registration alone.

The active window is not on-chain — the contract only stores a timestamp. The Worker
decides what counts as active (`SUBSCRIPTION_WINDOW_DAYS`, 30 days), so that policy is
tunable without a redeploy. Full doc: `subscription_registry/README.md`.

## SettlementRegistry

Anonymous paid access to a resource, via Semaphore. Standalone — it is not part of the
register/publish flow above and `deploy.sh` does not touch it.

Publishers `create_resource(uid, price, uri)` — the contract derives
`resourceId = keccak(publisher ++ uid)` and creates **a Semaphore group for that
resource**. Buyers `register(...)` with a USDC `transferWithAuthorization` (gasless
permit), which pays the resource's owner and adds their identity commitment to that
resource's group; `settle(...)` verifies a Semaphore proof against that same group,
burns a nullifier, and optionally fires a per-resource `afterSettle` hook. The contract
creates each group itself because it has to be the group admin — Semaphore's handover is
two-step, so accepting a group id from outside would brick `create_resource`.

`set_disabled(resourceId, bool)` (owner or admin) is the takedown flag: it blocks new
registrations and settlements, and the access gate is expected to consult `is_disabled`
before releasing a key. It does not un-settle existing buyers.

**v2 is a security rewrite and an ABI break.** v1 shared ONE group across the whole
registry, so a single payment to any publisher unlocked every resource forever — and a
free self-minted resource unlocked it for nothing. v1 also let the caller name the
payment recipient, and let anyone claim any resourceId. Do not run v1, and do not point
a v1 client at a v2 deployment. Rationale, migration steps and the open questions around
`set_disabled` are in `settlement_registry/README.md`.

## Build and test

```sh
cargo test --manifest-path data_registry/Cargo.toml
cargo test --manifest-path subscription_registry/Cargo.toml
cargo test --manifest-path settlement_registry/Cargo.toml
```

Tests run against the stylus-sdk `TestVM`, which mocks cross-contract calls
(`mock_static_call` / `mock_call`) but returns one value per transaction — so a single
test can't make `isRegistered` and `transferFrom` disagree.

## Generate ABI

```sh
cargo stylus export-abi --json   # from inside a crate dir; writes that crate's abi.json
```

Stylus exposes Rust `snake_case` as **camelCase** (`commitStateRoot`, `isRegistered`,
`setSubscriptionFee`). The snake_case selector reverts — this bites every new caller.

## Deploy (Arbitrum Sepolia)

```sh
./deploy.sh                    # interactive: both, DataRegistry only, or subscription only
./set_subscription_fee.sh 5    # admin: set the live subscription fee, in USDC
```

`deploy.sh` deploys the DataRegistry first, then the SubscriptionRegistry wired to it;
deploying the subscription alone prompts for an existing DataRegistry address. Config
is env vars with defaults in the script: `PRIVATE_KEY`, `RPC_ENDPOINT`, `MAX_FEE`,
`ADMIN_ADDR`, `USDC_ADDR`, `REGISTRATION_FEE`, `SUBSCRIPTION_FEE`,
`DATA_REGISTRY_ADDR`. Requires `cargo stylus` and `cast`.

Deploying mints new addresses, so afterwards repoint all three consumers:
`fangorn/src/config.ts`, `websites/fangorn/.env.local`, and
`webworker/pinata-url-provider/wrangler.toml`.

MVP, not audited.
</content>
