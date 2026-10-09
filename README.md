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

| Path                                    | What                                                    |
|-----------------------------------------|---------------------------------------------------------|
| `solidity/src/AppRegistry.sol`          | AppRegistry                                             |
| `solidity/src/DataRegistry.sol`         | DataRegistry                                            |
| `solidity/src/MembershipRegistry.sol`   | MembershipRegistry                                      |
| `solidity/src/NonReentrant.sol`         | Reentrancy guard shared by the contracts                |
| `solidity/test/`                        | Foundry tests and mocks                                 |
| `solidity/script/Deploy.s.sol`          | Deploys the contracts, each behind a proxy              |
| `solidity/script/Upgrade.s.sol`         | Admin: upgrade a deployed contract in place             |
| `solidity/script/SetSubscriptionFee.s.sol` | Admin: set the subscription fee on the AppRegistry   |
| `solidity/script/Deployments.sol`       | Each proxy's address, and each contract's current version |
| `solidity/deployed/`                    | The build of each contract that is live; what the upgrade-safety test compares storage with |
| `solidity/lib/`                         | `forge-std`, `openzeppelin-contracts-upgradeable`, `openzeppelin-foundry-upgrades` (submodules) |

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
  `upgradeToAndCall` (through `script/Upgrade.s.sol`) replaces the implementation. Setting a zero
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
  `upgradeToAndCall` (through `script/Upgrade.s.sol`) replaces the implementation. Setting a zero
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

Needs [Foundry](https://getfoundry.sh) and [Node.js](https://nodejs.org). The
libraries are git submodules under `solidity/lib/`; after a fresh clone run
`git submodule update --init --recursive`. OpenZeppelin Contracts (v5.7.0) is the copy
inside `openzeppelin-contracts-upgradeable`, which is how the
[OpenZeppelin Foundry Upgrades](https://docs.openzeppelin.com/upgrades-plugins/foundry/foundry-upgrades)
plugin is set up.

Node.js is for that plugin: it checks upgrade safety by running
`npx @openzeppelin/upgrades-core`, which is why `foundry.toml` turns on `ffi`. One test,
`UpgradeSafety`, runs the check on the current version of every contract, and compares
its storage with the build of that contract that is live (`solidity/deployed/`), so
`forge test` needs network access the first time. The check needs a full build: if it
fails with "not from a full compilation", run `forge clean` and try again.

The tests cover every case the Rust tests do, and the ones the Stylus test VM cannot
express: that ETH actually reaches the app owner, that a revert unwinds state, that a
missing or reverting partner registry fails closed, and that a hook cannot re-enter
`settle`. The AppRegistry tests run against the real DataRegistry rather than a mock.
Every test deploys its contracts behind a proxy, as the deploy script does, and each
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

## Deploy

Deploys, upgrades and admin calls are Forge scripts in `solidity/script/`. Run them
from `solidity/`. There are no shell scripts.

```sh
cd solidity
forge script script/Deploy.s.sol --sig "all()" --force \
  --rpc-url <rpc> --account <keystore> --sender <deployer address> --broadcast
```

| `--sig`                                 | Deploys                                                        |
|-----------------------------------------|----------------------------------------------------------------|
| `"all()"`                               | AppRegistry and DataRegistry, wired to each other, and the default app claimed |
| `"appRegistry(address)" <DataRegistry>` | A new AppRegistry in front of an existing DataRegistry, which is repointed at it |
| `"dataRegistry(address)" <AppRegistry>` | A new DataRegistry behind an existing AppRegistry, which is repointed at it |
| `"membershipRegistry(address)" <AppRegistry>` | A MembershipRegistry. The AppRegistry it reads app owners from cannot be changed later |

This is for a contract that does not exist yet. To change one that is already deployed,
see *Upgrade*: a redeploy starts empty at a new address.

- **`--force` is required.** The upgrade-safety check needs a full build and refuses a
  partial one.
- **Signing.** Keep the key in a Foundry keystore (`cast wallet import <name>
  --interactive`) and pass `--account <name> --sender <its address>`. No script reads a
  private key from the environment, and none belongs in a `.env`.
- **Nothing is sent unless everything would succeed.** Forge simulates the whole run
  first. A failed check, or a signer who is not the admin, stops it before the first
  transaction. Leave `--broadcast` off to only simulate.
- **Parameters** are environment variables, listed with their defaults in
  `solidity/.env.example` (Forge reads a `.env` in `solidity/`). `ADMIN_ADDR` is
  required and has no default; for the two registries it must be the signer, because
  the wiring calls are admin-only. `USDC_ADDR` and `SEMAPHORE_ADDR` default to the
  Arbitrum Sepolia deployments on that chain and are required on any other.

Each contract is two deployments: the implementation, then an ERC-1967 proxy (UUPS)
whose constructor runs `initialize`. The proxy's address is the contract's address: it
is what the script prints and what goes in the SDK. **Record it in
`script/Deployments.sol`**, which is where the other scripts find it, and commit the
broadcast log Forge writes under `solidity/broadcast/`.

`all()` deploys the AppRegistry, then the DataRegistry, points each at the other,
registers the deployer as a publisher, and only then claims the default app (`fangorn`):
a claim needs a registered claimer. With a non-zero `SUBSCRIPTION_FEE` the deployer
needs that much USDC.

Deploying mints new addresses. They reach every consumer through one place:
`fangorn/src/config.ts`. Publish the SDK, then bump it in the workers and the website.

### Setting the subscription fee

```sh
forge script script/SetSubscriptionFee.s.sol --sig "run(uint256)" 5000000 \
  --rpc-url <rpc> --account <keystore> --sender <admin address> --broadcast
```

The fee is in USDC base units (6 decimals): `5000000` is 5 USDC. Admin only.

## Upgrade

An upgrade replaces the code behind one proxy (`upgradeToAndCall`, admin-only). The
address and all state stay, so there is nothing to migrate and nothing to repoint in the
SDK, the workers or the other registry. If the ABI changed, the SDK still needs the new
ABI.

The OpenZeppelin Foundry Upgrades plugin checks every upgrade against the version it
replaces, so that version's source has to stay in the repo. That makes an upgrade four
steps:

1. **Add the new version as a new file and a new contract name.** Copy the current
   version, rename it, and name the version it replaces:

   ```solidity
   // src/DataRegistryV2.sol
   /// @custom:oz-upgrades-from DataRegistry
   contract DataRegistryV2 is Initializable, UUPSUpgradeable {
   ```

   Do not edit a version that is deployed. Its file is the reference the upgrade
   script checks the next version against. The `UpgradeSafety` test does catch a
   storage change made there, because it compares with the build in `deployed/`.

2. **Make it the current version** in `script/Deployments.sol`
   (`DATA_REGISTRY = "DataRegistryV2.sol:DataRegistryV2"`). From here `forge test`
   checks it against the live build in `deployed/`: the `UpgradeSafety` test fails on
   the pull request if a storage slot moved, changed type or disappeared.

3. **Run the upgrade**, signing as the contract's admin:

   ```sh
   forge script script/Upgrade.s.sol --sig "run(string)" DataRegistry --force \
     --rpc-url <rpc> --account <keystore> --sender <admin address> --broadcast
   ```

   The name is `AppRegistry`, `DataRegistry` or `MembershipRegistry`. The script takes
   the proxy's address and the new version from `Deployments.sol`, so one contract's
   code cannot be pointed at another contract's proxy. It runs the same check again and
   refuses a version that names no predecessor.

4. **Record the new version as the live one**, in the same pull request as the
   broadcast log. Rebuild its reference build, and name its contract in
   `Deployments.deployed` (`"DataRegistry:DataRegistryV2"`):

   ```sh
   rm -r deployed/DataRegistry
   forge build src/DataRegistryV2.sol --force --build-info --build-info-path deployed/DataRegistry
   ```

   Until this is done the test keeps comparing with the version that was replaced.
   The first deployment of a new contract needs the same step.

**Storage is append-only.** The proxy keeps its storage, so the new code must read every
existing slot the way the old code wrote it:

- Add state variables after the last one. Add struct fields at the end of the struct
  (`App` is only ever a mapping value, so it can grow).
- Never reorder, retype or remove a state variable or a struct field, and do not change
  the order of the contracts a registry inherits from.
- A constructor or an initial value on a state variable never reaches the proxy. New
  state that needs a starting value gets a `reinitializer(n)` function. Pass the call to
  it as a second argument and it runs in the upgrade transaction:
  `--sig "run(string,bytes)" DataRegistry $(cast calldata "initializeV2()")`.

The plugin enforces the first two, and also refuses constructors, `selfdestruct` and
`delegatecall` in a new version. A change that cannot keep the layout is a redeploy.

`MembershipRegistry` inherits OpenZeppelin's non-upgradeable `ERC721` and `EIP712`,
whose constructors the plugin would refuse. It is live with that storage, so they stay,
and `Deployments.options` allows them for that contract only; the comment there says why
it is safe.

**Rehearse first.** Fork the chain locally and run the same command against the fork,
signing as the admin's address without its key:

```sh
anvil --fork-url <rpc> --auto-impersonate
forge script script/Upgrade.s.sol --sig "run(string)" DataRegistry --force \
  --rpc-url http://127.0.0.1:8545 --unlocked --sender <admin address> --broadcast
```

MVP, not audited.
