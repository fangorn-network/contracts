# Fangorn contracts

Three Stylus (Rust → WASM) contracts on Arbitrum Sepolia. **No proxies, no factories,
no delegatecall** — each contract is deployed directly. When they need to talk, they do
it with a plain cross-contract call to a stored address, not through a shared storage
layout.

Almost nothing lives on-chain. A publisher's namespace is one `bytes32` in the
DataRegistry — the sha256 digest of its latest commit block. The graph itself is
content-addressed IPLD off-chain (IPFS/Pinata); the chain is the trusted pointer and
the lock that keeps the timeline linear.

## Architecture

```
  App owner ── registerApp() ──▶  AppRegistry  ◀── registerForApp() ── Publisher
  (wallet, USDC)                  (Stylus)                             (invited first)
     │ addPublisher(pub)           │  app → owner, terms, join fee
     │ renewApp()                  │  app → paid_at   (the subscription)
     ▼                             │  (app, publisher) → status
                                   │
                                   │ isRegistered(wallet)  ▼   on claim and on add
                                   │ isRegisteredForApp(app, sender)  ▲   on commit
                                   │  (static cross-calls, one each way)
  Publisher ── register() ──▶  DataRegistry  ◀── commitStateRoot(app, subspace, old, new)
  (wallet)                     (Stylus)            emits StateCommitted
                                                         │
                                                         ▼
                                                   SDK light-client
                                                   (watches logs, no indexer)

  Upload gate (Cloudflare Worker) reads:
    DataRegistry.getPublisherStatus(addr)        is this wallet a publisher at all?
    AppRegistry.access(app, addr)                → (registered, owner, paidAt)


  SettlementRegistry (Stylus, standalone) ──▶ Semaphore   ──▶ anonymous paid access
  resource pricing + USDC payment + nullifiers                (not wired to the above)
```

The two registries point at each other. The DataRegistry asks the AppRegistry who may
publish under an app while the AppRegistry asks the DataRegistry whether a wallet is a
registered publisher at all.
Each stores the other's address and can be repointed by the admin (`setAppRegistry`,
`setDataRegistry`), so replacing the one contract is a redeploy plus one call.

### Why each registry knows about the other

The two directions do different jobs.

| Direction                  | Asked when                           | Question                                               |
|----------------------------|--------------------------------------|--------------------------------------------------------|
| DataRegistry → AppRegistry | every commit                         | May this wallet publish under this app?                |
| AppRegistry → DataRegistry | claiming an app, adding a publisher  | Is this wallet a registered, unbanned publisher at all? |

**DataRegistry → AppRegistry.** The DataRegistry is where publishing actually happens,
so it is the only place app membership can be enforced on-chain.
`commit_state_root(app_id, …)` takes the app id from the caller, and before it moves
the head it asks the AppRegistry whether the sender is an active publisher of that app.
If not, it reverts `NotRegisteredForApp`.

Without that call, any registered wallet could commit under any app id. It could not
overwrite another publisher's data, because the namespace key includes the sender's
address. But its commits would carry the app's id in `StateCommitted`, so they would
appear in that app's commit stream for every reader and feed watching it. Everything
the AppRegistry decides would then be advisory on-chain:

- the owner's invitation,
- acceptance of the current terms,
- per-app suspension by the owner,
- the admin's takedown of a whole app.

The Worker cannot cover this on its own. It only gates uploads through Fangorn's hosted
storage, and anyone can pin bytes elsewhere and call `commitStateRoot` directly. The
contract cannot tell where the bytes were pinned.

**AppRegistry → DataRegistry.** The DataRegistry is where the protocol admin bans a
publisher network-wide (`suspend_publisher`). The AppRegistry asks it before letting a
wallet claim an app or be added to one, so a banned wallet cannot come back as an app
owner or be brought in by one. This check runs when those calls are made, not
continuously; see *Global bans* under AppRegistry for what happens to a wallet banned
later.

## Layout

| Path                   | Contract           | Toolchain    | Deployed by      |
|------------------------|--------------------|--------------|------------------|
| `app_registry/`        | AppRegistry        | cargo stylus | `deploy.sh`      |
| `data_registry/`       | DataRegistry       | cargo stylus | `deploy.sh`      |
| `settlement_registry/` | SettlementRegistry | cargo stylus | `deploy.sh`      |

## AppRegistry

Apps, who may publish under them, and who pays for their storage. **An app is a
storage subscription**: there is no app without a payment, and no subscription without
an app.

- `register_app(app_id, terms_hash, terms_uri, fee)` — claim an app id,
  first-come-first-served. Pulls the subscription fee in **USDC** via
  `IERC20::transferFrom` (**approve this contract first**; a refused pull reverts
  `SubscriptionFeeRequired`), stamps `subscribed_at[app_id] = now`, and makes the
  claimer the app's first publisher. `fee` is the app's own join fee, in wei. The
  claimer must be registered in the DataRegistry (`NotRegisteredGlobally` otherwise).
- `renew_app(app_id)` — owner-only. Pays the fee again and re-stamps `now`.
- `add_publisher(app_id, publisher)` — owner-only. An **invitation**: status goes
  `0 → 3`. Nobody can join an app uninvited. The publisher must be registered in the
  DataRegistry (`NotRegisteredGlobally` otherwise).
- `register_for_app(app_id, terms_hash)` — payable, called by the invited publisher.
  Accepts the exact current terms hash and pays the join fee (forwarded to the app
  owner). Reverts `NotInvited` for a wallet the owner never added. Re-accepting after a
  terms change is free.
- `set_app_terms`, `set_app_fee`, `set_app_agent_uri` — owner-only. Changing the terms
  unregisters every publisher until they re-accept; the agent card carries no hash, so
  moving it does not.
- `suspend_for_app` / `reinstate_for_app` — owner-only, one publisher in one app.
  Suspending an invited publisher is how an invitation is taken back.
- `suspend_app` / `reinstate_app` — admin-only takedown of a whole app.
- `access(app_id, publisher) → (bool registered, address owner, uint64 paid_at)` — the
  upload gate's single read. `registered` is `is_registered_for_app`.
- Views: `is_registered_for_app`, `status_for_app`, `join_info`, `get_app_owner`,
  `subscribed_at`, `subscription_fee`, `usdc`, `data_registry`, `app_terms`,
  `app_terms_uri`, `app_agent_uri`, `app_fee`, `accepted_terms`, `is_app_suspended`,
  `admin`.
- Admin: `set_subscription_fee`, `set_usdc`, `set_data_registry`, `withdraw_usdc`,
  `withdraw_eth`.
- `init(admin, usdc, subscription_fee, data_registry)`.

**Global bans.** "Registered in the DataRegistry" means status active, so a wallet the
protocol admin has suspended can neither claim an app nor be added to one. The check
runs when those calls are made. A publisher banned later already cannot commit (the
DataRegistry refuses) or upload (the Worker refuses). An *owner* banned later keeps
the app, and its other publishers keep publishing: take the app down with
`suspend_app`.

An AppRegistry with no DataRegistry set treats every wallet as unregistered, so
nothing can be claimed until it is wired.

Per-app status codes: `0` unregistered, `1` active, `2` suspended, `3` invited.
`is_registered_for_app` is true only for an active publisher on the app's current terms
hash, in an app that is not suspended.

The active window is not on-chain — the contract only stores a timestamp. The Worker
decides what counts as active (`SUBSCRIPTION_WINDOW_DAYS`, 30 days), so that policy is
tunable without a redeploy. A lapsed app therefore still passes
`is_registered_for_app`: the lapse stops uploads at the Worker, not commits on-chain.

## DataRegistry

Network-wide publisher registration and the state-root timeline.

State: `admin`, `registration_fee`, `statuses` (0 unregistered / 1 active /
2 suspended), `publisher_count`, `app_registry`, `namespace_heads`
(`keccak256(app_id ‖ publisher ‖ subspace_id) → bytes32`).

- `register()` — payable; pays the registration fee (native token) to become active. A
  suspended account cannot re-register. Only the admin can bring it back
  (`reinstate_global`), which preserves its heads.
- `commit_state_root(app_id, subspace_id, old_root, new_root)` — the only
  graph-mutating route. Rejects unless the caller is active here **and**
  `AppRegistry.isRegisteredForApp(app_id, caller)` (`NotRegisteredForApp`), then
  compare-and-swaps the head (`StaleStateRoot`). That CAS is what enforces a linear
  timeline. Emits `StateCommitted`, the single event the SDK's light-client watches.
- Views: `get_namespace_head`, `is_registered`, `get_publisher_status`,
  `publisher_count`, `registration_fee`, `app_registry`, `admin`.
- Admin: `suspend_publisher`, `reinstate_global`, `set_registration_fee`,
  `set_app_registry`, `seed_namespace_head` (fill-only; replays heads after a redeploy).
- `init(admin, registration_fee, app_registry)`.

So publishing takes two registrations, in this order: `register()` here, then
membership of an app (claiming it, or being added by its owner and accepting its
terms). The AppRegistry refuses the second without the first.

`commit_state_root` does not verify that `new_root` is a well-formed commit; it only
checks the CAS. The contract is deliberately structure-agnostic — it moves a
`bytes32`, and the SDK defines what that value means.

## SettlementRegistry

Anonymous paid access to a resource, via Semaphore. Standalone — it is not part of the
register/publish flow above.

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
(cd app_registry && cargo test)
(cd data_registry && cargo test)
(cd settlement_registry && cargo test)
```

Run from inside each crate: its `rust-toolchain.toml` pins the compiler, and
`cargo test --manifest-path …` from the repo root uses your default toolchain instead.

Tests run against the stylus-sdk `TestVM`, which mocks cross-contract calls
(`mock_static_call` / `mock_call`). Three limits shape the tests:

- A mock's success or revert is keyed by address and calldata, but there is **one
  shared return-data buffer** — the bytes of the last mock registered — and an unmocked
  call succeeds and reads it too. So two cross-calls can only disagree if one reverts.
- It does not model native value movement.
- It keeps storage writes made before an `Err` return, so a revert's unwinding can't be
  observed.

## Generate ABI

```sh
cargo stylus export-abi --json   # from inside a crate dir; writes that crate's abi.json
```

Stylus exposes Rust `snake_case` as **camelCase** (`commitStateRoot`, `isRegistered`,
`setSubscriptionFee`). The snake_case selector reverts — this bites every new caller.
The export omits events, so the SDK's ABI files carry those by hand.

## Deploy (Arbitrum Sepolia)

```sh
./deploy.sh                    # interactive: all, or one contract
TARGET=app-registry DATA_REGISTRY_ADDR=0x… ./deploy.sh   # new AppRegistry, same heads
./set_subscription_fee.sh 5    # admin: set the live subscription fee, in USDC
```

`deploy.sh` deploys the AppRegistry, then the DataRegistry, points each at the other,
registers the deployer as a publisher, and only then claims the default app
(`fangorn`) — a claim needs a registered claimer. Deploying the AppRegistry alone
requires `DATA_REGISTRY_ADDR`: the new contract is born pointing at it, and it is
repointed at the new one. Config is env
vars (or a gitignored `.env`): `PRIVATE_KEY`, `RPC_ENDPOINT`, `MAX_FEE`, `ADMIN_ADDR`,
`USDC_ADDR`, `REGISTRATION_FEE`, `SUBSCRIPTION_FEE`, `DATA_REGISTRY_ADDR`,
`APP_REGISTRY_ADDR`. Requires `cargo stylus` and `cast`.

The AppRegistry compresses to about 28.3 KB, over the 24 KB single-contract limit, so
`cargo stylus` deploys it as two fragments. Arbitrum Sepolia allows that
(`ArbOwnerPublic.getMaxStylusContractFragments()` is 4); check the same call on any
other chain before deploying there.

A new AppRegistry starts empty: every app is re-claimed (and paid for) and its
publishers re-added. With a non-zero `SUBSCRIPTION_FEE` the deployer needs that much
USDC to claim the default app.

Deploying mints new addresses. They reach every consumer through one place:
`fangorn/src/config.ts`. Publish the SDK, then bump it in the workers and the website.

MVP, not audited.
</content>
