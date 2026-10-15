# Fangorn contracts

The three core Fangorn contracts written in Solidity: the AppRegistry, the DataRegistry and the MembershipRegistry. Sources, tests and scripts are in `solidity/`.

**The contracts are upgradeable.** Each implemented contract is behind its own ERC-1967 proxy (UUPS). See *Upgrade*.

Almost nothing lives on-chain. A publisher's namespace is one `bytes32`, `keccak256(app_id || publisher || subspace_id)`, stored in the DataRegistry. The graph itself is content-addressed IPLD off-chain (IPFS/Pinata). The DataRegistry represents the onchain pointer to the latest head.

## Architecture

```
  App owner ── registerApp() ──▶  AppRegistry  ◀── joinApp() ── Publisher
  (wallet, USDC)                   ▲  │          ◀── commitStateRoot(app, subspace, old, new)
     │ invitePublisher(pub)        │  │  app → owner, terms, join fee
     │ renewSubscription()         │  │  app → expiry (the subscription), ERC-721 token
     ▼                             │  │  (app, publisher) → status
  Admin ── setGlobalSuspension() ──┘  │  wallet → globalSuspensions (network-wide ban)
  (network-wide ban)                  │
                                      │ commitStateRoot(app, publisher, subspace, old, new)
                                      │  forwarded once the publisher is checked
                                      ▼
                                 DataRegistry   accepts commits from the AppRegistry only
                                                emits StateCommitted
                                                         │
                                                         ▼
                                                   SDK light-client
                                                   (watches logs, no indexer)

  Upload gate (Cloudflare Worker) reads:
    AppRegistry.access(app, addr)                → (canPublish, owner, expiresAt)
                                                   canPublish is false for a banned wallet


  Reader ── join() / claim() ──▶ MembershipRegistry ──▶ Semaphore
  (USDC, ERC-3009)               plan per app, locked expiring ERC-721
                                 reads AppRegistry.getAppOwner(app): who sets the
                                 plan, and who is paid
```

Publishers commit through the AppRegistry which proxies the call to the DataRegistry. It decides who may publish (apps, memberships and the protocol admin's network-wide ban all live in it) and forwards each commit it allows to the DataRegistry, which accepts commits from that AppRegistry and no one else. Each stores the other's address and the admin can repoint either (`setDataRegistry`, `setAppRegistry`), so replacing one contract is a deploy plus two calls.

### Contract Communication

| Direction                  | Called when                          | What                                                   |
|----------------------------|--------------------------------------|--------------------------------------------------------|
| AppRegistry → DataRegistry | every commit                         | Move this publisher's head since the AppRegistry has validated the call |

`AppRegistry.commitStateRoot(app_id, …)` requires the sender to be an active publisher of that app (`canPublish`: invited, joined on the current terms, not suspended from the app or banned network-wide, and in an app that is not suspended), else it reverts with the reason (see `commitStateRoot` under AppRegistry). It then calls `DataRegistry.commitStateRoot` with the sender's address as the publisher.

## Layout

| Path                                    | What                                                    |
|-----------------------------------------|---------------------------------------------------------|
| `solidity/src/AppRegistry.sol`          | AppRegistry                                             |
| `solidity/src/DataRegistry.sol`         | DataRegistry                                            |
| `solidity/src/MembershipRegistry.sol`   | MembershipRegistry                                      |
| `solidity/src/IERC5643.sol`             | The ERC-5643 subscription interface the Membership and App registries implement |
| `solidity/test/`                        | Foundry tests and mocks                                 |
| `solidity/script/Deploy.s.sol`          | Deploys the contracts behind their own UUPS proxy              |
| `solidity/script/Upgrade.s.sol`         | Admin: upgrade a deployed contract in place             |
| `solidity/script/SetSubscriptionFee.s.sol` | Admin: set the subscription fee on the AppRegistry   |
| `solidity/script/Deployments.sol`       | Each proxy's address, and what each contract is upgraded with |
| `solidity/script/Builds.sol`            | Writes and checks the builds in `deployed/`, for the two scripts above |
| `solidity/deployed/`                    | The build of each contract that is live. What an upgrade, and the upgrade-safety test, compare storage with. |
| `solidity/lib/`                         | `forge-std`, `openzeppelin-contracts-upgradeable`, `openzeppelin-foundry-upgrades` (submodules) |

## Common to the contracts

- *Names.* Functions are `camelCase`. Arguments and event fields are `snake_case` (`app_id`, `new_root`).
- *Reentrancy.* Every function that moves funds or makes a state-changing call to another contract is guarded with OpenZeppelin's `ReentrancyGuardTransient`, which keeps its flag in transient storage (EIP-1153) rather than a storage slot, and reverts `ReentrancyGuardReentrantCall()` if re-entered. Views are not guarded. `AppRegistry.commitStateRoot` is guarded because it calls the DataRegistry.
- *Cross-calls.* There is only one cross contract call: `AppRegistry.commitStateRoot` calls `DataRegistry.commitStateRoot`. A refusal there (`StaleStateRoot`) reaches the caller unchanged, and the AppRegistry declares that error so it is in its ABI too. With no DataRegistry set, every commit reverts.
- *Upgradeability.* Each contract takes its initial arguments through `initialize(…)` and has `upgradeToAndCall`, `proxiableUUID` and `UPGRADE_INTERFACE_VERSION`, the `Initialized` and `Upgraded` events, and
  OpenZeppelin's proxy errors.
- *Admin.* One address per contract. It is also who may upgrade it. `setAdmin(new_admin)` hands the role over and emits `AdminChanged`. Setting the zero address **renounces the role and permanently stops upgrades**.

## AppRegistry

Apps, who may publish under them, and who pays for their storage. **An app is synonymous to a storage subscription** so data availability has stronger guarantees.

**Each app is an ERC-721 token** (`FANGAPP`), id `uint256(app_id)`, minted to its owner at claim, and **its subscription follows [ERC-5643](https://eips.ethereum.org/EIPS/eip-5643)**. One payment of `subscriptionFee` (USDC) buys `subscriptionPeriod` seconds. The token cannot be transferred or burned (`NotTransferable`), so its owner is always `getAppOwner`.

- `registerApp(app_id, terms_hash, terms_uri, join_fee, max_subscription_fee)`: claim an app id, first-come-first-served. Pulls the subscription fee in **USDC** via `IERC20.transferFrom` (**approve this contract first**; a refused pull reverts `SubscriptionFeeRequired`). If the fee is above `max_subscription_fee` when the claim lands, it reverts `SubscriptionFeeTooHigh` instead, so a fee raised above what the caller wanted to pay isn't charged. Then it mints the app's token to the claimer, sets its expiry one period from now, and makes the claimer the app's first publisher. `join_fee` is the app's own join fee, in wei. `terms_hash` must not be zero (`TermsNotSet`), here or in `setAppTerms`, so an app always has terms to accept. The claimer must not be banned network-wide (`PublisherSuspendedGlobal` otherwise).
- `renewSubscription(token_id, duration)`: ERC-5643. The owner, or an address they approved for the token, pays the fee for one more period (USDC; approve this contract first). `duration` must be `subscriptionPeriod` (`DurationMismatch`), and the app must be renewable (`SubscriptionNotRenewable`). The renewal call will succeed only when less than one period is left, so nobody pays more than a period ahead. The period is added to the expiry, or to now if it has passed. Sends no ETH (`EthNotAccepted`). Emits `SubscriptionUpdate(token_id, expiry)`. The standard fixes the arguments, so there is no maximum fee making the payer's allowance the cap. Approve exactly `subscriptionFee()`, and a fee raised in the meantime makes the renewal revert.
- `cancelSubscription(token_id)`: ERC-5643, the owner only (`Unauthorized` otherwise, approved addresses included). Ends the subscription now, as the standard does: the expiry becomes `0`, with no refund, and `SubscriptionUpdate(token_id, 0)` is emitted. The app stays claimed and a renewal starts a new period from now.
- `expiresAt(token_id)`, `isRenewable(token_id)`: ERC-5643. Both revert for a token that does not exist (`ERC721NonexistentToken`). `isRenewable` is true once less than one period is left.
- ERC-721: `ownerOf`, `balanceOf`, `approve`, `getApproved`, `setApprovalForAll`, `isApprovedForAll`, `name`, `symbol`, `tokenURI` (empty), `supportsInterface` (ERC-165, ERC-721, its metadata, and ERC-5643's `0x8c65f84d`). The transfer functions revert.
- `invitePublisher(app_id, publisher)`: owner-only. Reverts `AlreadyInvited` for a wallet the app already knows. An **invitation**: status goes `0 → 3`. Nobody can join an app uninvited. The publisher must not be banned network-wide (`PublisherSuspendedGlobal` otherwise).
- `joinApp(app_id, terms_hash)`: payable, called once by the invited publisher. Accepts the exact current terms hash and pays exactly the join fee (any other amount reverts `JoinFeeMismatch`). The fee is credited to the app owner. Reverts `NotInvited` for a wallet the owner never added, `PublisherSuspendedApp` for one suspended from the app, and `PublisherSuspendedGlobal` for one banned network-wide. Joining happens once and subsequent attempts reverts with `AlreadyJoined`. Nobody can join an app whose subscription has expired (`SubscriptionExpired`) so no fees are collected by an owner of a defunct app.
- `acceptUpdatedTerms(app_id, terms_hash)`: a member whose accepted terms the owner has since replaced accepts the current ones, and can publish again. The call is free so an owner cannot bill every member by editing the terms. Emits `UpdatedTermsAccepted`. Reverts `NotJoined` for a publisher who has only been invited, `TermsMismatch` for anything but the current terms, and `TermsAlreadyAccepted` if they already accepted them.
- `setAppTerms`, `setJoinFee`, `setAppAgentUri`: owner-only. Changing the terms stops every publisher publishing until they accept the new ones (`acceptUpdatedTerms`). The agent card carries no hash, so moving it does not change the terms.
- `revokeInvitation(app_id, publisher)`: owner-only. Revokes the invitation an invited publisher has not accepted. They are treated as if they were never invited so they cannot join and can be invited again. Emits `PublisherInvitationRevoked`. Reverts `NotInvited` for a wallet the app has not invited, and `AlreadyJoined` for a member (suspend them if the intent is to remove them from being a publisher).
- `setPublisherSuspended(app_id, publisher, bool)`: owner-only. Change the suspension status of one member in one app. Emits `PublisherSuspensionChanged`. Only a publisher who has joined can be suspended (`NotJoined` for one only invited; revoke the invitation instead), so lifting a suspension always makes them a member again. Suspending a wallet the app does not know reverts `NotInvited`. Lifting a suspension that is not there reverts `PublisherNotSuspended`. The owner cannot suspend themselves (`CannotSuspendOwner`).
- `setAppSuspended(app_id, bool)`: admin-only takedown of a whole app. Memberships are left intact. Emits `AppSuspensionChanged`.
- `setGlobalSuspension(wallet, bool)`: admin-only network-wide ban of any address, including one that has never published. Emits `GlobalSuspensionChanged`.
- `commitStateRoot(app_id, subspace_id, old_root, new_root)`: the only way to publish. Unless the sender `canPublish`, it reverts with the first reason that applies:

  | Error | The sender… |
  |---|---|
  | `AppNotFound` | names an app that doesn't exist |
  | `PublisherSuspendedGlobal` | is banned network-wide by the protocol admin |
  | `AppSuspended` | names an app the protocol admin has suspended |
  | `SubscriptionExpired` | names an app whose subscription has expired or been cancelled (checked after the bans and takedown) |
  | `PublisherSuspendedApp` | is suspended from this app by its owner |
  | `NotInvited` | was never added to the app |
  | `NotJoined` | was added but has not joined (`joinApp`) |
  | `TermsMismatch` | accepted terms the app has since replaced. Accept the new terms with `acceptUpdatedTerms` |

  Otherwise it forwards the commit to the DataRegistry, which compare-and-swaps the head of `app_id:sender:subspace_id` (`StaleStateRoot` if `old_root` is not it) and emits `StateCommitted`.
- `access(app_id, publisher) → (bool can_publish, address owner, uint64 expires_at)`: the upload gate's (Cloudflare worker) single read. `can_publish` is `canPublish`, so it is false once the subscription has expired; `expires_at` is the subscription's expiry, `0` for an unclaimed app or a cancelled subscription.
- Views: `canPublish`, `statusForApp`, `joinFeesOwed`, `joinInfo`, `getAppOwner`, `subscriptionFee`, `subscriptionPeriod`, `usdc`, `dataRegistry`, `globalSuspensions`, `appTerms`, `appTermsUri`, `appAgentUri`, `joinFee`, `acceptedTerms`, `isAppSuspended`, `admin`.
- `withdrawJoinFees(to)`: an app owner takes out every join fee their apps have collected (`joinFeesOwed(owner)`, one balance across all their apps) and sends it to `to`, so an owner contract that cannot take ETH names an address that can. Reverts `NothingToWithdraw` if nothing is owed. Emits `JoinFeesWithdrawn`.
- Admin: `setSubscriptionFee`, `setSubscriptionPeriod` (not zero, `ZeroPeriod`; applies from each app's next payment, emits `SubscriptionPeriodChanged`), `setDataRegistry` (emits `DataRegistryChanged`), `withdrawToken(token, to, amount)` (the collected USDC, or any ERC-20 sent here by mistake; emits `TokenWithdrawn`). The fee token is fixed at `initialize`. The contract's ETH is the join fees owed to app owners.
- Admin: `setAdmin`, and `upgradeToAndCall` through `script/Upgrade.s.sol`.
- `initialize(admin, usdc, subscription_fee, subscription_period)`.

**Global bans.** A wallet the protocol admin has banned can't claim an app, be added to one, nor accept an invitation. A wallet banned later cannot publish in any app (`canPublish` is false), so it cannot commit (`PublisherSuspendedGlobal`) or upload (the Worker refuses). An *owner* banned later keeps the app, and its other publishers keep publishing. The app can be taken down with `setAppSuspended`.

**Expiry is enforced on-chain.** Once an app's subscription has expired or been cancelled, nobody can commit to it (`canPublish` is false) or join it (`SubscriptionExpired`), so no join fee is paid into an app that cannot be used. Managing members (inviting, revoking, accepting updated terms, suspending) stays open, join fees already earned can still be withdrawn, and nothing is lost. Renewing the app returns functionality to normal. There is no grace period when an app expires.

## DataRegistry

The state-root timeline.

State: `admin`, `appRegistry`, `namespaceHeads` (`keccak256(app_id ‖ publisher ‖ subspace_id) → bytes32`).

- `commitStateRoot(app_id, publisher, subspace_id, old_root, new_root)`: The only graph-mutating route, callable by the AppRegistry only (`Unauthorized` otherwise), which has checked that `publisher` may publish under `app_id`. Publishers call `AppRegistry.commitStateRoot`. It compare-and-swaps (CAS) the head which enforces a linear timeline. Emits `StateCommitted` the SDK's light-client watches.
- Views: `getNamespaceHead`, `appRegistry`, `admin`.
- Admin: `setAppRegistry` (the one address that may commit; until it is set, nobody can).
- Admin: `setAdmin`, and `upgradeToAndCall` through `script/Upgrade.s.sol`.
- `initialize(admin, app_registry)`.

`commitStateRoot` does not verify that `new_root` is a well-formed commit; it only checks the CAS. The contract is deliberately structure-agnostic. It only moves a `bytes32`, and the SDK defines what that value means.

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

It replaces the old SettlementRegistry.

## Build and test

```sh
cd solidity
forge build
forge test
```

Needs [Foundry](https://getfoundry.sh) and [Node.js](https://nodejs.org). The libraries are git submodules under `solidity/lib/`; after a fresh clone run `git submodule update --init --recursive`. OpenZeppelin Contracts (v5.7.0) is the copy inside `openzeppelin-contracts-upgradeable`, which is how the [OpenZeppelin Foundry Upgrades](https://docs.openzeppelin.com/upgrades-plugins/foundry/foundry-upgrades) plugin is set up.

Node.js is for that plugin: it checks upgrade safety by running `npx @openzeppelin/upgrades-core`, which is why `foundry.toml` turns on `ffi`. One test, `UpgradeSafety`, runs the check on every contract, and compares its storage with the build of that contract that is live (`solidity/deployed/`), so `forge test` needs network access the first time. The check needs a full build so if it fails with "not from a full compilation", run `forge clean` and try again.

The tests check, among the rest, that ETH actually reaches the app owner, that a revert unwinds state, and that the DataRegistry takes commits from the AppRegistry only. The AppRegistry tests run against the real DataRegistry rather than a mock; USDC and Semaphore are mocks. Every test deploys its contracts behind a proxy, as the deploy script does, and each suite checks that only the admin can upgrade.

## Generate ABI

```sh
(cd solidity && forge inspect src/AppRegistry.sol:AppRegistry abi --json)
```

When a contract's ABI changes, update the SDK's ABI files to match.

## Deploy

Deploys, upgrades and admin calls are Forge scripts in `solidity/script/`. Run them from `solidity/`.

```sh
cd solidity
forge script script/Deploy.s.sol --sig "all()" --force \
  --rpc-url <rpc> --account <keystore> --sender <deployer address> --broadcast
```

| `--sig`                                 | Deploys                                                        |
|-----------------------------------------|----------------------------------------------------------------|
| `"all()"`                               | All three registries, the AppRegistry and DataRegistry wired to each other, and the default app is claimed |
| `"appRegistry(address)" <DataRegistry>` | A new AppRegistry in front of an existing DataRegistry, which is repointed at it |
| `"dataRegistry(address)" <AppRegistry>` | A new DataRegistry behind an existing AppRegistry, which is repointed at it |
| `"membershipRegistry(address)" <AppRegistry>` | A MembershipRegistry. The AppRegistry it reads app owners from cannot be changed later |

This is for a contract that does not exist yet. To change one that is already deployed, see *Upgrade*: a redeploy starts empty at a new address.

- **`--force` is required.** The upgrade-safety check needs a full build and refuses a
  partial one.
- **Signing.** Keep the key in a Foundry keystore (`cast wallet import <name> --interactive`) and pass `--account <name> --sender <its address>`. No script reads a private key from the environment.
- **Nothing is sent unless everything would succeed.** Forge simulates the whole run first. A failed check, or a signer who is not the admin, stops it before the first transaction. Leave `--broadcast` off to only simulate.
- **Parameters** are environment variables, listed with their defaults in `solidity/.env.example` (Forge reads a `.env` in `solidity/`). `ADMIN_ADDR` is required and has no default; for the two registries it must be the signer, because
  the wiring calls are admin-only. `USDC_ADDR` and `SEMAPHORE_ADDR` default to the Arbitrum Sepolia deployments.

Each contract is two deployments: the implementation, then an ERC-1967 proxy (UUPS) whose constructor runs `initialize`. The proxy's address is the contract's address: it is what the script prints and what goes in the SDK. **Record it in `script/Deployments.sol`**, which is where the other scripts find it.

With `--broadcast` the script also writes each new contract's build, under `deployed/<Contract>/<implementation address>/`, replacing any older build of that contract: it is what the first upgrade is checked against (see *Upgrade*). It should be committed together with the addresses in `Deployments.sol` and the broadcast log Forge writes under `solidity/broadcast/`. The `UpgradeSafety` test fails while the two disagree: a contract has builds when `Deployments.sol` records its proxy.

`all()` deploys the AppRegistry, then the DataRegistry, points each at the other, then deploys the MembershipRegistry and claims the default app (`fangorn`) for the deployer. With a non-zero `SUBSCRIPTION_FEE` the deployer needs an appropriate balance of USDC. `SUBSCRIPTION_PERIOD` (seconds, default 30 days) is how long one payment lasts.

### Setting the subscription fee

```sh
forge script script/SetSubscriptionFee.s.sol --sig "run(uint256)" 5000000 \
  --rpc-url <rpc> --account <keystore> --sender <admin address> --broadcast
```

 Admin only. The fee is in USDC base units (6 decimals): `5000000` is 5 USDC.

## Upgrade

An upgrade replaces the code behind one proxy (`upgradeToAndCall`, admin-only). The address and all state stay, so there is nothing to migrate and nothing to repoint in the SDK, the workers or the other registry. If the ABI changed, the SDK will need the new ABI.

The OpenZeppelin Foundry Upgrades plugin checks every upgrade against the version it replaces. A contract keeps its file and its name from one version to the next, so a pull request shows what changed and not a second copy of the contract. What the plugin compares with is therefore the build of the live version, committed under `solidity/deployed/<Contract>/<implementation address>/` (its `referenceBuildInfoDir` option; `Deployments.upgradeOptions` sets it). That makes an upgrade two steps:

1. **Edit the contract in place** (`src/DataRegistry.sol`). From here `forge test` checks it against the builds in `deployed/`: the `UpgradeSafety` test fails on the pull request if a storage slot moved, changed type or disappeared.

2. **Run the upgrade**, signing as the contract's admin:

   ```sh
   forge script script/Upgrade.s.sol --sig "run(string)" DataRegistry --force \
     --rpc-url <rpc> --account <keystore> --sender <admin address> --broadcast
   ```

   The names are `AppRegistry`, `DataRegistry` or `MembershipRegistry`.

The script takes the proxy's address and the contract from `Deployments.sol`, so one contract's code cannot be pointed at another contract's proxy. It runs the same check again, after confirming that the build it checks against is the code behind the proxy. If it is not, the script stops before sending anything. The script also writes the build of the new version, to `deployed/DataRegistry/<new implementation address>/`. Commit it with the broadcast log. The first build of each contract is written by `Deploy.s.sol`.

**What is in `deployed/<Contract>/`.** One directory per build, named after the implementation it is the build of: the live one and, after an upgrade, the one it replaced, which the next upgrade removes. The new build is written next to the live one and not over it because the script runs before its transactions are sent. If they fail, the live build is untouched and the upgrade can simply be run again. Without `--broadcast` nothing is written. A rehearsal against a fork does write a build: delete it (`git clean -fd deployed`) or leave it for the real run to replace.

To confirm, without a signer, that every contract has a build of its live code:

```sh
forge script script/Upgrade.s.sol --sig "check()" --rpc-url <rpc>
```

It compares runtime code, leaving out constructor-set immutables and the compiler's metadata hash, so a build from source that differs only in a comment passes and one from source with different logic does not. CI **does not** run it.

Between merging a change and running its upgrade, `src/` is ahead of the chain: `deployed/` is what says which code is live. Earlier versions of a contract are in the git history.

**Storage is append-only.** The proxy keeps its storage, so the new code must read every existing slot the way the old code wrote it:

- Add state variables after the last one. Add struct fields at the end of the struct (`App` is only ever a mapping value, so it can grow).
- Never reorder, retype or remove a state variable or a struct field, and do not change the order of the contracts a registry inherits from.
- A constructor or an initial value on a state variable never reaches the proxy. New state that needs a starting value gets a `reinitializer(n)` function. Pass the call to it as a second argument and it runs in the upgrade transaction: `--sig "run(string,bytes)" DataRegistry $(cast calldata "initializeV2()")`.

The plugin enforces the first two, and also refuses constructors, `selfdestruct` and `delegatecall` in a new version. A change that cannot keep the layout must be a full redeploy.

The contracts inherit OpenZeppelin's upgradeable variants (`ERC721Upgradeable`, `EIP712Upgradeable`), which keep their state in namespaced storage and set it in `initialize`, so the plugin needs no exemption for any of them.

**Rehearse first.** Fork the chain locally and run the same command against the fork, signing as the admin's address without its key:

```sh
anvil --fork-url <rpc> --auto-impersonate
forge script script/Upgrade.s.sol --sig "run(string)" DataRegistry --force \
  --rpc-url http://127.0.0.1:8545 --unlocked --sender <admin address> --broadcast
```

MVP, not audited.
