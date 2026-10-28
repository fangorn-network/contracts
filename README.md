# Fangorn contracts

The three core Fangorn contracts written in Solidity: the AppRegistry, the DataRegistry and the MembershipRegistry. Sources, tests and scripts are in `solidity/`.

**The contracts are upgradeable.** Each implemented contract is behind its own ERC-1967 proxy (UUPS). See *Deploy and upgrade*.

Almost nothing lives on-chain. A publisher's repo is `(publisher, name)`, and its head is one `bytes32` in the DataRegistry: the onchain pointer to its latest commit. The data itself is content-addressed and stored off-chain. A repo belongs to no app. An app is **sponsored storage**: it pays for its members' uploads, and presents its members' repos.

## Deployed

Use the proxy addresses: an upgrade only changes the implementation behind them. `solidity/script/Deployments.sol` is the source of truth.

| Contract           | Arbitrum Sepolia (421614)                    | Base Sepolia (84532)                         |
| ------------------ | -------------------------------------------- | -------------------------------------------- |
| AppRegistry        | `0x55e6209ea1833ceD900989a3b3b22466934E04A5` | `0x0D3e98399df41b558048Cdd7D71723c37A3A9D6F` |
| DataRegistry       | `0x72B5f83526F3893aF9f1eE0f32A27218EA09f8aE` | `0xE9183f768865dd2Cde5f1B71F8446F0Cd798ebe0` |
| MembershipRegistry | `0xDF17030Cd65435C86eb043F31DDACa99E819E347` | `0x0e96C012b5c53622EcDAA82F342E31C2623A04f5` |
| Admin              | `0xB2F5361DBEF0715E1d6aa072284255dD7f1d43FC` | `0x7b16387C5A8c514880E48bcacd52782FCF9Da936` |
| RPC                | `https://sepolia-rollup.arbitrum.io/rpc`     | `https://sepolia.base.org`                   |

## Architecture

```
  Publisher ── update(repo, parent, head) ──▶ DataRegistry   (P, keccak(repo)) → (pos, head)
                anyone, for their own repos      emits Updated

  App owner ── registerApp()                 ──▶  AppRegistry   app → owner, expiry
     │ acceptPublisher(app, P)                │  (app, P) → status; canPublish = accepted, in good standing
     │ setPublisherSuspended(app, P, bool)    │  (app, exclusion) → count; odd = excluded
     │ exclude / restore  publisher, repo or key │  emits PublisherAccepted, ExclusionChanged
  Admin ── setGlobalSuspension() / setAppSuspended() ┘
                                                     │
                                                     ▼
                                               clients read views and logs

  An off-chain upload gate reads, for the app the caller names:
    AppRegistry.access(app, addr)                → (canPublish, owner, expiresAt)

  Reader ── join() / claim() ──▶ MembershipRegistry ──▶ Semaphore
  (USDC, ERC-3009)               plan per app, locked expiring ERC-721
                                 reads AppRegistry.getAppOwner(app): who sets the
                                 plan, and who is paid
```

Publishing and membership are separate. Any address updates its own repos in the DataRegistry, and an update names no app. Membership of an app is the AppRegistry's, and the owner's alone: `acceptPublisher` is the whole of it. Neither contract calls the other.

### How it behaves

**An app is sponsored storage for the publishers it accepts, and includes their data.** The owner accepts a publisher (`acceptPublisher`); from then one rule, `canPublish(app, publisher)`, decides both: the upload gate pins the publisher's bytes for the app while it holds, and the app includes that publisher's repos while it holds. What an app presents of a repo is the publisher's latest head (`getHead`), unless the app excludes the publisher, the repo, or a record key in it. A repo read under no app is just its head.

`canPublish` holds while the app has accepted the publisher and not suspended it, the publisher is not banned network-wide, and the app is neither taken down nor past its subscription. It changes no head, so presentation follows it immediately, in both directions:

- **A member publishes:** one `update` moves the head, and the app presents it.
- **Anyone else publishes:** the update stands, and the app presents nothing of it. Hosted storage refuses its uploads.
- **One wallet, several apps:** each app that has the publisher as a member presents its latest head, with its own exclusions.
- **A member is suspended:** the app stops presenting the publisher entirely, earlier heads included. Its updates keep landing. Reinstated, the app presents its latest head again.
- **The subscription lapses, or the admin takes the app down:** the app presents nobody until it is renewed or reinstated. Nothing is lost.
- **The protocol admin bans a wallet:** no app presents or stores it.

**Exclusions** are the owner's finer tool. `exclude` withdraws a publisher, one of its repos, or one record key from the app, for all of its past, until `restore`. They never touch the DataRegistry: the publisher's head, and every other app's view of it, are unchanged.

There is no per-head acceptance: an app cannot hold a member at an older head, nor present a non-member.

## Layout

| Path                                       | What                                                                                                         |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `solidity/src/AppRegistry.sol`             | AppRegistry                                                                                                  |
| `solidity/src/DataRegistry.sol`            | DataRegistry                                                                                                 |
| `solidity/src/MembershipRegistry.sol`      | MembershipRegistry                                                                                           |
| `solidity/src/IERC5643.sol`                | The ERC-5643 subscription interface the Membership and App registries implement                              |
| `solidity/test/`                           | Foundry tests and mocks                                                                                      |
| `solidity/script/Deploy.s.sol`             | Deploys the contracts behind their own UUPS proxy                                                            |
| `solidity/script/Upgrade.s.sol`            | Admin: upgrade a deployed contract in place                                                                  |
| `solidity/script/SetSubscriptionFee.s.sol` | Admin: set the subscription fee on the AppRegistry                                                           |
| `solidity/script/Deployments.sol`          | Each proxy's address, and what each contract is upgraded with                                                |
| `solidity/script/Builds.sol`               | Writes and checks the builds in `deployed/`, for the two scripts above                                       |
| `solidity/deployed/`                       | The build of each contract that is live. What an upgrade, and the upgrade-safety test, compare storage with. |
| `solidity/lib/`                            | `forge-std`, `openzeppelin-contracts-upgradeable`, `openzeppelin-foundry-upgrades` (submodules)              |

## Common to the contracts

- *Names.* Functions are `camelCase`. Arguments and event fields are `snake_case` (`app_id`, `repo_id`).
- *Reentrancy.* Every function that moves funds is guarded with OpenZeppelin's `ReentrancyGuardTransient`, which keeps its flag in transient storage (EIP-1153) rather than a storage slot, and reverts `ReentrancyGuardReentrantCall()` if re-entered. Views are not guarded.
- *Upgradeability.* Each contract takes its initial arguments through `initialize(…)` and has `upgradeToAndCall`, `proxiableUUID` and `UPGRADE_INTERFACE_VERSION`, the `Initialized` and `Upgraded` events, and
  OpenZeppelin's proxy errors.
- *Admin.* One address per contract. It is also who may upgrade it. `setAdmin(new_admin)` hands the role over and emits `AdminChanged`. Setting the zero address **renounces the role and permanently stops upgrades**.

## AppRegistry

Apps, who may publish under them, and who pays for their storage. **An app is synonymous to a storage subscription** so data availability has stronger guarantees.

**Each app is an ERC-721 token** (`FANGAPP`), id `uint256(app_id)`, minted to its owner at claim, and **its subscription follows [ERC-5643](https://eips.ethereum.org/EIPS/eip-5643)**. One payment of `subscriptionFee` (USDC) buys `subscriptionPeriod` seconds. The token cannot be transferred or burned (`NotTransferable`), so its owner is always `getAppOwner`.

- `registerApp(app_id, max_subscription_fee)`: claim an app id, first-come-first-served. Pulls the subscription fee in **USDC** via `IERC20.transferFrom` (**approve this contract first**; a refused pull reverts `SubscriptionFeeRequired`). If the fee is above `max_subscription_fee` when the claim lands, it reverts `SubscriptionFeeTooHigh` instead, so a fee raised above what the caller wanted to pay isn't charged. Then it mints the app's token to the claimer, sets its expiry one period from now, and makes the claimer the app's first accepted publisher (`PublisherAccepted`). The claimer must not be banned network-wide (`PublisherSuspendedGlobal` otherwise). The zero id cannot be claimed (`ZeroAppId`), nor an id another app goes by (`AppAlreadyRegistered`).
- `renewSubscription(token_id, duration)`: ERC-5643. The owner, or an address they approved for the token, pays the fee for one more period (USDC; approve this contract first). `duration` must be `subscriptionPeriod` (`DurationMismatch`), and the app must be renewable (`SubscriptionNotRenewable`). The renewal call will succeed only when less than one period is left, so nobody pays more than a period ahead. The period is added to the expiry, or to now if it has passed. Sends no ETH (`EthNotAccepted`). Emits `SubscriptionUpdate(token_id, expiry)`. The standard fixes the arguments, so there is no maximum fee making the payer's allowance the cap. Approve exactly `subscriptionFee()`, and a fee raised in the meantime makes the renewal revert.
- `cancelSubscription(token_id)`: ERC-5643, the owner only (`Unauthorized` otherwise, approved addresses included). Ends the subscription now, as the standard does: the expiry becomes `0`, with no refund, and `SubscriptionUpdate(token_id, 0)` is emitted. The app stays claimed and a renewal starts a new period from now.
- `expiresAt(token_id)`, `isRenewable(token_id)`: ERC-5643. Both revert for a token that does not exist (`ERC721NonexistentToken`). `isRenewable` is true once less than one period is left.
- ERC-721: `ownerOf`, `balanceOf`, `approve`, `getApproved`, `setApprovalForAll`, `isApprovedForAll`, `name`, `symbol`, `tokenURI` (empty), `supportsInterface` (ERC-165, ERC-721, its metadata, and ERC-5643's `0x8c65f84d`). The transfer functions revert.
- `acceptPublisher(app_id, publisher)`: owner-only. The whole membership: status goes `None → Active`, and from then the publisher uploads with the app's storage and the app includes its data, while `canPublish` holds. No invitation, terms or fee. Emits `PublisherAccepted`. Reverts `AlreadyAccepted` for a publisher the app has accepted, suspended or not (reinstate a suspended one with `setPublisherSuspended(…, false)`). Neither the owner nor the publisher may be banned network-wide (`PublisherSuspendedGlobal`).
- `setAppAgentUri(app_id, agent_uri)`: owner-only. Moving the agent card leaves the app's publishers alone.
- `renameApp(app_id, new_id)`: owner-only, and not for an owner banned network-wide (`PublisherSuspendedGlobal`). Gives the app a new id. Nothing moves: `new_id` becomes an alias of the id the app was claimed under (its *canonical* id), so its publishers, exclusions, subscription and token carry on, and **every function taking an `app_id` accepts any id the app has gone by**. Old ids stay the app's, so nobody can claim one and pass as the app to clients still using it; renaming back to one is allowed. `new_id` held by another app reverts `AppAlreadyRegistered`, zero reverts `ZeroAppId`. Emits `AppRenamed(app_id, new_id)` with the canonical id. The token id, the listings (`appsPage`, `appsOf`) and every event keep the canonical id; `currentAppId(app_id)` gives the id the app goes by now, `canonicalAppId(app_id)` the one it was claimed under (both return an id that is no app's unchanged).
- `setPublisherSuspended(app_id, publisher, bool)`: owner-only. Change the suspension status of one member in one app. Emits `PublisherSuspensionChanged`. Only a publisher the app accepted can be suspended (`NotAccepted` otherwise), so lifting a suspension always makes them a member again. Lifting a suspension that is not there reverts `PublisherNotSuspended`. The owner cannot suspend themselves (`CannotSuspendOwner`).
- `setAppSuspended(app_id, bool)`: admin-only takedown of a whole app. Memberships are left intact. Emits `AppSuspensionChanged`.
- `setGlobalSuspension(wallet, bool)`: admin-only network-wide ban of any address, including one that has never published. Emits `GlobalSuspensionChanged`.
- `exclude(app_id, publisher, repo_id, key_id)` / `restore(…)`: owner-only. Withdraws from the app a publisher (`repo_id` and `key_id` zero), one of its repos (`key_id` zero), or one record key, for all of its past, or lifts it. Each exclusion is a counter, `exclusionCount(app_id, exclusionId(publisher, repo_id, key_id))`, odd while in force: `exclude` needs it even (`AlreadyExcluded`), `restore` odd (`NotExcluded`). Names stay hashed. Emits `ExclusionChanged`.
- `access(app_id, publisher) → (bool can_publish, address owner, uint64 expires_at)`: the off-chain upload gate's single read. `can_publish` is `canPublish`, so it is false once the subscription has expired; `expires_at` is the subscription's expiry, `0` for an unclaimed app or a cancelled subscription.
- Views (each `app_id` may be any id the app goes by): `canPublish`, `exclusionCount`, `exclusionId`, `statusForApp` (`0` none, `1` accepted, `2` suspended; `3` is an invitation left from an earlier version, not a member, accepted like `0`), `joinFeesOwed`, `getAppOwner`, `currentAppId`, `canonicalAppId`, `subscriptionFee`, `subscriptionPeriod`, `usdc`, `dataRegistry`, `globalSuspensions`, `appAgentUri`, `isAppSuspended`, `admin`.
- `withdrawJoinFees(to)`: earlier versions charged publishers a join fee. Nothing collects one now, but an owner still takes out what they are owed (`joinFeesOwed(owner)`, one balance across all their apps), in USDC, to `to`. Reverts `NothingToWithdraw` if nothing is owed, and `TransferFailed` (leaving the balance owed) if the token refuses. Emits `JoinFeesWithdrawn`.
- Admin: `setSubscriptionFee`, `setSubscriptionPeriod` (not zero, `ZeroPeriod`; applies from each app's next payment, emits `SubscriptionPeriodChanged`), `setDataRegistry` (emits `DataRegistryChanged`), `withdrawToken(token, to, amount)` (the protocol's USDC, or any ERC-20 sent here by mistake; emits `TokenWithdrawn`). Of USDC, only the protocol's share can be taken and is calculated by subtracting the contract's balance from the join fees owed to app owners (`totalJoinFeesOwed`), else it reverts `ExceedsProtocolBalance`. The fee token is fixed at `initialize`. Every token transfer goes through OpenZeppelin's `SafeERC20`, so tokens that return no value from `transfer` work too.
- Admin: `setAdmin`, and `upgradeToAndCall` through `script/Upgrade.s.sol`.
- `appCount()`, `appsPage(offset, limit)`, `appsOf(owner)`: every claimed app id, and each owner's, oldest first. What clients list apps from instead of scanning `AppRegistered` logs. Expired and suspended apps stay listed; the per-app reads say which. `appsPage` returns fewer ids, or none, past the end.
- `initialize(admin, usdc, subscription_fee, subscription_period)`.

**Global bans.** A wallet the protocol admin has banned can't claim an app or be accepted into one. A wallet banned later cannot publish in any app (`canPublish` is false), so no app presents it or sponsors its uploads. An *owner* banned later keeps the app, and its other publishers keep publishing, but the owner cannot accept anyone (which would let them keep publishing through new wallets) or move its agent card: `acceptPublisher` and `setAppAgentUri` revert `PublisherSuspendedGlobal`. The app can be taken down with `setAppSuspended`.

**Expiry is enforced on-chain.** Once an app's subscription has expired or been cancelled, it sponsors and includes nothing (`canPublish` is false). Managing publishers (accepting, suspending) stays open, and nothing is lost. Renewing the app returns functionality to normal. There is no grace period when an app expires.

## DataRegistry

The heads of every repo, and the update log as events.

State: `admin`, `appRegistry`, `heads` (`publisher → keccak256(repo) → (pos, head)`), and the retired `namespaceHeads`, kept so storage stays append-only.

- `update(repo, parent, head)`: move the sender's `repo` from `parent` to `head` (`StaleStateRoot` unless `parent` is the head; `ZeroHead` for a zero head). Any address, for its own repos: no app, fee or registration. Emits `Updated(publisher, repo_id, repo, pos, parent, head)`, with the name in clear.
- Views: `getHead(publisher, repo_id) → (pos, head)`, `appRegistry`, `admin`.
- Admin: `setAppRegistry` (the AppRegistry this one names; nothing calls it).
- Admin: `setAdmin`, and `upgradeToAndCall` through `script/Upgrade.s.sol`.
- `initialize(admin, app_registry)`.

`update` does not verify that `head` is a well-formed commit, nor the commit's epoch; it only checks the CAS. It only moves a `bytes32`, and clients define what that value means.

## MembershipRegistry

Time-limited access to an app's paid records, held by an address nobody can tie to the
wallet that paid. It reads one thing from the AppRegistry: who owns an app. That address
is fixed at deployment; there is no setter for it.

- `setPlan(app_id, price, period)` — app owner only. What one period of membership
  costs, in USDC base units, and how long a period is. Price zero means the app offers
  none. Changing `period` renumbers epochs, so do it rarely.
- `join(app_id, commitment, salt, pay)` — anyone may submit it. `pay` is the payer's
  signed ERC-3009 `receiveWithAuthorization` for exactly the plan's price. The USDC goes
  to the app's owner, and the Semaphore identity `commitment` joins the group of
  (app, current epoch), which the contract creates on first use. The signature's nonce
  must be `joinNonce(app_id, epoch, commitment, salt)`, so whoever submits it cannot
  swap in another commitment, and only this contract can redeem it.
- `claim(app_id, epoch, holder, merkleTreeDepth, merkleTreeRoot, nullifier, points)` —
  a Semaphore proof of membership in that group, with `holder` as its message. Mints the
  holder's membership, or extends it by one period: from its expiry if still current,
  from now if lapsed. One claim per payment (`AlreadyClaimed` on a reused nullifier).
- `canRead(tokenId, who) → (app_id, until)` — the access gate's read: the membership's
  expiry for its holder, the user's expiry for its user, otherwise zero.
- `setUser(tokenId, user, expires)` — the holder names one user, typically an agent,
  never past the membership's own expiry. `setUserBySig` takes the holder's signature
  (EIP-712, or ERC-1271 for a contract wallet) so a holder with no gas can do it.
- Views: `planOf`, `currentEpoch`, `joinNonce`, `scopeOf`, `groupOf`, `tokenIdOf`,
  `appOfToken`, `expiresAt`, `isRenewable`, `userOf`, `userExpires`, `userNonces`,
  `locked`, `usdc`, `semaphore`, `appRegistry`, `admin`.
- Admin: `setAdmin`, and `upgradeToAndCall` through `script/Upgrade.s.sol`.
- `initialize(admin, usdc, semaphore, app_registry)`.

The membership is an ERC-721 with one token per (app, holder): `tokenIdOf(app_id,
holder)`. It is locked (ERC-5192): it can be minted, and every transfer and burn reverts
`NotTransferable`. It expires (the reads of ERC-5643) and has one user (ERC-4907).
`renewSubscription` and `cancelSubscription` revert `UseJoinAndClaim`: renewing is
another `join` and `claim`, which keeps the payer unlinked from the holder, and a
membership ends by not renewing.

## Build and test

```sh
cd solidity
forge build
forge test
```

Needs [Foundry](https://getfoundry.sh) and [Node.js](https://nodejs.org). The libraries are git submodules under `solidity/lib/`; after a fresh clone run `git submodule update --init --recursive`. OpenZeppelin Contracts (v5.7.0) is the copy inside `openzeppelin-contracts-upgradeable`, which is how the [OpenZeppelin Foundry Upgrades](https://docs.openzeppelin.com/upgrades-plugins/foundry/foundry-upgrades) plugin is set up.

Node.js is for that plugin: it checks upgrade safety by running `npx @openzeppelin/upgrades-core`, which is why `foundry.toml` turns on `ffi`. One test, `UpgradeSafety`, runs the check on every contract, and compares its storage with the build of that contract that is live (`solidity/deployed/`), so the first `forge test` needs internet access to download that npm package. The check needs a full build so if it fails with "not from a full compilation", run `forge clean` and try again.

The tests check, among the rest, that only the owner accepts publishers, that join fees still owed reach the app owner and stay out of the admin's reach, that a revert unwinds state, and that every way out of an app (`canPublish` false) is also a refusal at the upload gate (`access`). The AppRegistry tests run against the real DataRegistry rather than a mock. USDC and Semaphore are mocks. Every test deploys its contracts behind a proxy, as the deploy script does, and each suite checks that only the admin can upgrade.

**The tests never touch a real network.** `forge test` runs every test on a local chain that Forge simulates in memory. The contracts are deployed there, the ETH and tokens the tests use are made up (`vm.deal`, the mocks), and the chain is thrown away when the test ends. Nothing is deployed to Arbitrum Sepolia or any other network, and no test ETH is spent. The only commands that send real transactions are scripts run with `--broadcast` (see *Deploy and upgrade*).

## Generate ABI

```sh
(cd solidity && forge inspect src/AppRegistry.sol:AppRegistry abi --json)
```

When a contract's ABI changes, clients need the new ABI.

## Deploy and upgrade

Everything here runs from `solidity/`. `<keystore>` and `<admin>` are explained under *Signing*; the RPCs and admins are in *Deployed*.

### Commands

**Ship what `src/` says.** This is the usual one. It upgrades every contract whose code changed since it was deployed and leaves the rest:

```sh
forge script script/Upgrade.s.sol --force \
  --rpc-url <rpc> --account <keystore> --sender <admin> --broadcast
```

Then commit what it wrote under `deployed/` and `broadcast/`. Leave off `--broadcast` to see what it would do: it prints `up to date` or the upgrade for each contract.

| What                                   | Command (add `--rpc-url <rpc> --account <keystore> --sender <admin> --broadcast`) |
| -------------------------------------- | --------------------------------------------------------------------------------- |
| Upgrade one contract only              | `forge script script/Upgrade.s.sol --force --sig "upgrade(string)" DataRegistry`  |
| Set the subscription fee (USDC, 6 dp)  | `forge script script/SetSubscriptionFee.s.sol --sig "run(uint256)" 5000000`        |
| Rotate the admin of all three          | `forge script script/RotateAdmin.s.sol --sig "run(address)" <new admin>`          |
| First deployment on a new chain        | `forge script script/Deploy.s.sol --force --sig "all()"` (see *First deployment*) |
| Check `deployed/` is the live code     | `forge script script/Upgrade.s.sol --sig "check()" --rpc-url <rpc>` (no signer)   |

Every script simulates the whole run first and sends nothing unless all of it would succeed, so a wrong signer or a failed check costs nothing. `--force` is required wherever it is shown: the upgrade-safety check needs a full build.

### Signing

Scripts sign with a Foundry keystore: a private key stored encrypted under `~/.foundry/keystores/<name>`. `<keystore>` is that name. Import each key once:

```sh
cast wallet import admin-base --interactive   # paste the private key, then choose a password
cast wallet list                              # the names you have imported
cast wallet address --account admin-base      # the address behind it: pass it as --sender
```

Forge asks for the password when it signs. For a hardware wallet, pass `--ledger` instead of `--account`. No script reads a private key from the environment.

Each chain has its own admin, and every call except a first deployment must be signed by it. Import one keystore per admin (e.g. `admin-arb`, `admin-base`).

### Rotating the admin

Each registry keeps its own admin. `RotateAdmin.s.sol` moves all three at once, and first checks that all three still have the admin it records for the chain, so they cannot quietly drift apart. It refuses the zero address. After it runs, update the address it records.

### How an upgrade works

An upgrade replaces the code behind a proxy (`upgradeToAndCall`, admin-only). The address and all state stay, so nothing is migrated or repointed. If the ABI changed, clients need the new ABI.

1. **Edit the contract in place** (e.g. `src/DataRegistry.sol`). `forge test` checks it against the builds of the live versions, committed under `deployed/<chain id>/<Contract>/<implementation address>/`: the `UpgradeSafety` test fails if a storage slot moved, changed type or disappeared.
2. **Run the upgrade** (*Commands*), once per chain.

The script finds each proxy and its source in `Deployments.sol`. It compares the code in `src/` with the live code, ignoring comments, to decide what is out of date. Before upgrading, it confirms that the build in `deployed/` is the live code, and the OpenZeppelin plugin checks the new code's storage against it. With `--broadcast` it writes the new version's build next to the live one, and removes the one before. Commit it with the broadcast log: it is what the next upgrade is checked against.

Between merging a change and running its upgrade, `src/` is ahead of the chain. `deployed/` is what says which code is live.

**Storage is append-only.** The proxy keeps its storage, so the new code must read every existing slot the way the old code wrote it:

- Add state variables after the last one. Add struct fields at the end of the struct (`App` is only ever a mapping value, so it can grow).
- Never reorder, retype or remove a state variable or a struct field, and do not change the order of the contracts a registry inherits from.
- A constructor or an initial value on a state variable never reaches the proxy. New state that needs a starting value gets a `reinitializer(n)` function. Pass the call to it as a second argument and it runs in the upgrade transaction: `--sig "upgrade(string,bytes)" DataRegistry $(cast calldata "initializeV2()")`.

The plugin enforces the first two, and also refuses constructors, `selfdestruct` and `delegatecall` in a new version. A change that cannot keep the layout must be a full redeploy.

The contracts inherit OpenZeppelin's upgradeable variants (`ERC721Upgradeable`, `EIP712Upgradeable`), which keep their state in namespaced storage and set it in `initialize`, so the plugin needs no exemption for any of them.

**Rehearse first.** Fork the chain locally and run the same command against the fork, signing as the admin's address without its key:

```sh
anvil --fork-url <rpc> --auto-impersonate
forge script script/Upgrade.s.sol --force \
  --rpc-url http://127.0.0.1:8545 --unlocked --sender <admin> --broadcast
```

A rehearsal writes a build under `deployed/`: delete it (`git clean -fd deployed`) or leave it for the real run to replace.

### First deployment

Only for a chain with nothing on it yet: a redeploy starts empty at a new address. To change a deployed contract, upgrade it.

```sh
forge script script/Deploy.s.sol --force --sig "all()" \
  --rpc-url <rpc> --account <keystore> --sender <deployer> --broadcast
```

| `--sig`                                       | Deploys                                                                                |
| --------------------------------------------- | -------------------------------------------------------------------------------------- |
| `"all()"`                                     | All three registries, the AppRegistry and DataRegistry naming each other               |
| `"appRegistry(address)" <DataRegistry>`       | A new AppRegistry in front of an existing DataRegistry, which is repointed at it       |
| `"dataRegistry(address)" <AppRegistry>`       | A new DataRegistry behind an existing AppRegistry, which is repointed at it            |
| `"membershipRegistry(address)" <AppRegistry>` | A MembershipRegistry. The AppRegistry it reads app owners from cannot be changed later |

Parameters are environment variables, with defaults in `solidity/.env.example` (Forge reads `solidity/.env`):

- `ADMIN_ADDR`: required. For `all()`, `appRegistry()` and `dataRegistry()` it must be the signer, because the wiring calls are admin-only.
- `USDC_ADDR`, `SEMAPHORE_ADDR`: default to Arbitrum Sepolia's and Base Sepolia's; required on any other chain.
- `SUBSCRIPTION_FEE`: what claiming or renewing an app costs, in USDC base units. Default 0.
- `SUBSCRIPTION_PERIOD`: how long one payment lasts, in seconds. Default 30 days.

Afterwards:

1. Record each printed proxy address in `script/Deployments.sol`. The other scripts find the contracts there.
2. Commit the builds the script wrote under `deployed/<chain id>/`, along with the broadcast log. The first upgrade is checked against them. `UpgradeSafety` fails while the builds and `Deployments.sol` disagree.
3. Add the admin to `script/RotateAdmin.s.sol` and the chain to *Deployed* above.

MVP, not audited.
