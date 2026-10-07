# Fangorn contracts

Three contracts on Arbitrum Sepolia, each implemented twice: in Solidity
(`solidity/`) and as Stylus Rust → WASM (`stylus/`). The two implementations have the
same ABI and take the same initial arguments, so the SDK, the workers and `deploy.sh`
work with either. See *Two implementations* below for when to use which.

**The Solidity contracts are upgradeable.** Each sits behind its own ERC-1967 proxy
(UUPS): the proxy holds the address and the state, and the admin can swap the
implementation behind it, so changing a contract needs no migration and no new
address. See *Upgrade*. The Stylus contracts are deployed directly and cannot be
upgraded. Either way the three contracts are separate: when they need to talk, they do
it with a plain cross-contract call to a stored address, not through shared storage.

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

| Path                              | What                                               |
|-----------------------------------|----------------------------------------------------|
| `solidity/src/AppRegistry.sol`    | AppRegistry                                        |
| `solidity/src/DataRegistry.sol`   | DataRegistry                                       |
| `solidity/src/SettlementRegistry.sol` | SettlementRegistry                             |
| `solidity/src/NonReentrant.sol`   | Reentrancy guard shared by the ports               |
| `solidity/test/`                  | Foundry tests and mocks                            |
| `stylus/app_registry/`            | AppRegistry (cargo stylus crate)                   |
| `stylus/data_registry/`           | DataRegistry (cargo stylus crate)                  |
| `stylus/settlement_registry/`     | SettlementRegistry (cargo stylus crate)            |
| `solidity/lib/`                   | `forge-std`, `openzeppelin-contracts` (submodules) |
| `scripts/deploy.sh`               | Deploys either implementation (`IMPL=`)            |
| `scripts/upgrade.sh`              | Admin: upgrade a deployed Solidity contract in place |
| `scripts/layout.sh`               | Storage-layout check used by the two above         |
| `scripts/migrate.sh`              | Admin: copy the registries' state into new ones    |
| `scripts/set_subscription_fee.sh` | Admin: set the subscription fee on an AppRegistry  |
| `layout/<chain-id>/`              | The storage layout live on each chain (generated)  |

## Two implementations

The Solidity contracts are ports of the Stylus ones, written so that nothing outside
this repo has to know which is deployed.

**What is the same.** Every function name, argument order, return shape, error name and
event (including the `snake_case` event field names the SDK reads). Everything in the
Stylus `export-abi` output and in the ABI files the SDK ships is in the `forge inspect`
output, unchanged; the Solidity side adds only what is listed under *What differs*. One
detail worth knowing: `SettlementRegistry.settle` takes its hook data as `uint8[]`, not
`bytes`, because the Stylus contract declared it `Vec<u8>` and existing clients encode
it that way.

**What differs.**

- *Reentrancy.* A Stylus contract refuses reentrant calls unless it opts in. Solidity
  does not, so the ports guard every function that calls out (`NonReentrant.sol`) and
  expose one extra error, `Reentrancy()`. Views are not guarded: a hook may read the
  registry it was called from, which the Stylus version would refuse.
- *Failed cross-calls.* The registries treat anything but a clean `true` from the other
  registry (a revert, no contract at the address, a malformed return) as "no". The
  ports use low-level calls to get the same result; a plain interface call would revert
  on the last two instead.
- *Storage layout.* Unrelated. Neither implementation can be upgraded in place to the
  other; moving between them is a redeploy.
- *`resourceIdFor`* is `pure` in Solidity and `view` in the Stylus ABI. Callers cannot
  tell the difference.
- *Migration seeding.* Three admin-only functions exist in Solidity alone: `seedApp` and
  `seedPublisherForApp` on the AppRegistry, `seedPublisher` on the DataRegistry. They are
  what `migrate.sh` writes with. Nothing else calls them, and the SDK's ABI files do not
  list them.
- *Upgradeability.* Solidity only. Each contract takes its initial arguments through
  `initialize(…)` instead of a constructor (same arguments, same order), and adds
  `upgradeToAndCall`, `proxiableUUID` and `UPGRADE_INTERFACE_VERSION`, the `Initialized`
  and `Upgraded` events, and OpenZeppelin's proxy errors. The SDK's ABI files do not
  list these either.
- *Admin handover.* The Solidity AppRegistry and DataRegistry have `setAdmin(new_admin)`
  and an `AdminChanged` event, because the admin is also who may upgrade them. The
  Stylus ones have no way to change their admin. (The SettlementRegistry has `setAdmin`
  in both.)

**They interoperate.** A Solidity AppRegistry can be paired with a Stylus DataRegistry
and the reverse, since each only makes one view call on the other.

**Which to deploy.** Stylus needs the chain to accept new program activations. Arbitrum
paused those on 2026-10-02; while that holds, only the Solidity contracts can be
deployed. Check with:

```sh
cast call 0x0000000000000000000000000000000000000071 "activationGas()(uint64)" --rpc-url <rpc>
# a value in the millions is normal; 18446744073709551615 means activations are paused
```

Programs that were already activated keep running until their activation expires
(a year from when it happened).

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
- Admin, Solidity only, for `migrate.sh`: `seedApp(app_id, owner, terms_hash, terms_uri,
  fee, agent_uri)` recreates an app for its owner, pulls **no** subscription fee and
  stamps it as paid now (a testnet shortcut); `seedPublisherForApp(app_id, publisher,
  status, accepted_terms)` restores one membership verbatim. Both are fill-only: they
  refuse an app that is already claimed, or a publisher the app already knows.
- Admin, Solidity only: `setAdmin(new_admin)` hands the role over, and
  `upgradeToAndCall` (through `upgrade.sh`) replaces the implementation. Setting a zero
  admin renounces both for good.
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
- Admin, Solidity only, for `migrate.sh`: `seedPublisher(publisher)` restores one
  registration without the fee. Fill-only: it refuses a wallet the registry already
  knows, so it cannot lift a suspension.
- Admin, Solidity only: `setAdmin(new_admin)` hands the role over, and
  `upgradeToAndCall` (through `upgrade.sh`) replaces the implementation. Setting a zero
  admin renounces both for good.
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

### Solidity

```sh
cd solidity
forge build
forge test
```

Needs [Foundry](https://getfoundry.sh). `forge-std` and `openzeppelin-contracts`
(v5.7.0, for the proxy and the upgrade logic) are git submodules under `solidity/lib/`:
after a fresh clone run `git submodule update --init`.

The tests cover every case the Rust tests do, and the ones the Stylus test VM cannot
express: that ETH actually reaches the app owner, that a revert unwinds state, that a
missing or reverting partner registry fails closed, and that a hook cannot re-enter
`settle`. The AppRegistry tests run against the real DataRegistry rather than a mock.
Every test deploys its contracts the way `deploy.sh` does, behind a proxy, and each
suite checks that an upgrade keeps the state, that only the admin can upgrade, and that
`initialize` cannot run twice or on the bare implementation.

### Stylus

```sh
(cd stylus/app_registry && cargo test)
(cd stylus/data_registry && cargo test)
(cd stylus/settlement_registry && cargo test)
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
(cd solidity && forge inspect src/AppRegistry.sol:AppRegistry abi --json)
(cd stylus/app_registry && cargo stylus export-abi --json)
```

Stylus exposes Rust `snake_case` as **camelCase** (`commitStateRoot`, `isRegistered`,
`setSubscriptionFee`). The snake_case selector reverts — this bites every new caller.
The Stylus export omits events, so the SDK's ABI files carry those by hand; the
Solidity output includes them.

When a contract changes, change both implementations and compare the two ABIs before
touching the SDK.

## Deploy (Arbitrum Sepolia)

```sh
./scripts/deploy.sh                    # interactive: all, or one contract (Solidity by default)
IMPL=stylus ./scripts/deploy.sh        # the Stylus crates instead
TARGET=app-registry DATA_REGISTRY_ADDR=0x… ./scripts/deploy.sh   # new AppRegistry, same heads
./scripts/set_subscription_fee.sh 5    # admin: set the live subscription fee, in USDC
```

`deploy.sh` is for a contract that does not exist yet. To change one that is already
deployed (Solidity), use `upgrade.sh` instead: see *Upgrade*.

A Solidity contract is two deployments: the implementation, then the ERC-1967 proxy,
whose constructor runs `initialize` with the arguments. The proxy's address is the
contract's address: it is what `deploy.sh` prints and what goes in the SDK. The script
also records the storage layout it deployed in `layout/<chain-id>/`; commit those
files.

`deploy.sh` deploys the AppRegistry, then the DataRegistry, points each at the other,
registers the deployer as a publisher, and only then claims the default app
(`fangorn`) — a claim needs a registered claimer. Deploying the AppRegistry alone
requires `DATA_REGISTRY_ADDR`: the new contract is born pointing at it, and it is
repointed at the new one. That works across implementations, so a Solidity AppRegistry
can replace a Stylus one in front of a live Stylus DataRegistry.

Config is env vars (or a gitignored `.env` at the repo root; `.env.example` lists every
variable of every script, and a value in `.env` wins over the command line): `IMPL`, `TARGET`, `PRIVATE_KEY`,
`RPC_ENDPOINT`, `ADMIN_ADDR`, `USDC_ADDR`, `SEMAPHORE_ADDR`, `REGISTRATION_FEE`,
`SUBSCRIPTION_FEE`, `DATA_REGISTRY_ADDR`, `APP_REGISTRY_ADDR`, and `MAX_FEE` (Stylus
only). Requires `cast`, plus `forge` and `jq` for Solidity or `cargo stylus` for Stylus.

To try a deploy without spending anything, point it at a local chain:

```sh
anvil &
PRIVATE_KEY=<an anvil dev key> ADMIN_ADDR=<its address> \
  RPC_ENDPOINT=http://127.0.0.1:8545 TARGET=all ./scripts/deploy.sh
```

**What a redeploy loses.** Each contract starts empty at a new address. This is what
`upgrade.sh` avoids, so a redeploy is only for a first deployment, a storage-layout
change, or a move between Stylus and Solidity.

- AppRegistry and DataRegistry: everything, until `migrate.sh` copies it back (below).
  With a non-zero `SUBSCRIPTION_FEE` the deployer needs that much USDC to claim the
  default app.
- SettlementRegistry: every resource, Semaphore group and settlement is gone, so
  existing buyers lose access. Nothing migrates it.

**Stylus size.** The Stylus AppRegistry compresses to about 28.3 KB, over the 24 KB
single-contract limit, so `cargo stylus` deploys it as two fragments. Arbitrum Sepolia
allows that (`ArbOwnerPublic.getMaxStylusContractFragments()` is 4); check the same
call on any other chain before deploying there. The Solidity AppRegistry is about
11.0 KB of runtime code.

Deploying mints new addresses. They reach every consumer through one place:
`fangorn/src/config.ts`. Publish the SDK, then bump it in the workers and the website.

## Upgrade

```sh
CONTRACT=AppRegistry PROXY=0x… ./scripts/upgrade.sh
```

Replaces the code of one deployed Solidity contract. It deploys a new implementation
and points the existing proxy at it (`upgradeToAndCall`, admin-only). The address and
all state stay, so there is nothing to migrate and nothing to repoint in the SDK, the
workers or the other registry. If the ABI changed, the SDK still needs the new ABI.

`CONTRACT` is `AppRegistry`, `DataRegistry` or `SettlementRegistry`; `PROXY` is its
address. Run it with the admin key. The script refuses to start if the key is not the
contract's admin, if the address is not a proxy, or if the proxy is a different
contract than `CONTRACT` names (that mix-up would leave it with no admin, for good).

**Storage is append-only.** The proxy keeps its storage, so the new code must read
every existing slot the way the old code wrote it:

- Add state variables after the last one. Add struct fields at the end of the struct
  (`App` is only ever a mapping value, so it can grow).
- Never reorder, retype or remove a state variable or a struct field, and do not
  change the order of the contracts a registry inherits from.
- A constructor or an initial value on a state variable never reaches the proxy. New
  state that needs a starting value gets a `reinitializer(n)` function; pass its
  calldata as `INIT_DATA` and it runs in the same transaction as the upgrade.

`upgrade.sh` enforces the first two with `layout.sh`: it compares the working tree
against `layout/<chain-id>/<Contract>.txt`, which `deploy.sh` and each upgrade write,
and stops if a live slot moved, changed type or disappeared. A rename fails the check
too; it is harmless, so confirm that is all it is and re-record with
`./scripts/layout.sh write <Contract> <chain-id>`. Commit the snapshot after every deploy and
upgrade.

A change that cannot keep the layout is a redeploy plus `migrate.sh`, as before.

To rehearse an upgrade, deploy to a local chain as shown under *Deploy*, then run
`upgrade.sh` against it with the same key and `RPC_ENDPOINT`.

## Migrate

```sh
APP_REGISTRY_ADDR=0x… DATA_REGISTRY_ADDR=0x… ./scripts/migrate.sh
```

Copies the old registries' state into new Solidity ones (the targets must have the seed
functions). Run it after `deploy.sh`, with the admin key:

- DataRegistry: every registered publisher (a suspended one stays suspended) and every
  namespace head.
- AppRegistry: every app, for its original owner, with its terms, join fee, agent card
  and suspension flag; and every membership, with the terms hash that publisher
  accepted.

**Testnet only.** A migrated app pays no subscription fee and reads as paid at the
moment it was seeded, whatever it had paid before.

The old contracts' logs are only used to list which apps, publishers and namespaces
exist. Each value is read from the old contracts' views, so the copy is their state now.

It is safe to re-run: anything the new contracts already hold is left alone, and every
item is compared with the old contracts whether or not it was copied in that run. It
exits non-zero if anything differs. That includes an app `deploy.sh` claimed for a
different owner than the old one, so keep the deployer the same or give the default app
another name (`DEFAULT_APP_NAME`).

When only the AppRegistry was redeployed, pass the DataRegistry it sits in front of as
`DATA_REGISTRY_ADDR`: if that is the old one, the DataRegistry half is skipped.

Config is env vars (or the same `.env`): `PRIVATE_KEY`, `RPC_ENDPOINT`,
`APP_REGISTRY_ADDR`, `DATA_REGISTRY_ADDR`, `OLD_APP_REGISTRY`, `OLD_DATA_REGISTRY`
(both default to the Stylus deployment), `OLD_RPC_ENDPOINT` and `FROM_BLOCK`. Requires
`cast` and `jq`.

To rehearse it without spending anything, read the old state from Sepolia and write to
a local chain:

```sh
anvil &
PRIVATE_KEY=<an anvil dev key> ADMIN_ADDR=<its address> DEFAULT_APP_NAME=bootstrap \
  RPC_ENDPOINT=http://127.0.0.1:8545 TARGET=all ./scripts/deploy.sh
PRIVATE_KEY=<the same key> RPC_ENDPOINT=http://127.0.0.1:8545 \
  OLD_RPC_ENDPOINT=https://sepolia-rollup.arbitrum.io/rpc \
  APP_REGISTRY_ADDR=<new> DATA_REGISTRY_ADDR=<new> ./scripts/migrate.sh
```

MVP, not audited.
