# Fangorn contracts

This repo contains the core contracts required for the Fangorn protocol. See [Fangorn SDK](https://github.com/fangorn-network/fangorn).

> ⚠️ This code is not audited. Use at your own risk.

 <!-- the DataRegistry and the SettlementRegistry. Sources, tests and scripts are in `solidity/`.

**The contracts are upgradeable.** Each is behind its own ERC-1967 proxy (UUPS). See *Deploy and upgrade*.

Almost nothing lives on-chain. A publisher's repo is `(publisher, name)`, and its head is one `bytes32` in the DataRegistry: the name of its latest commit. The data is content-addressed and stored off-chain. -->

## Deployed Contracts

The latest contracts are deployed to Base Sepolia:

| Contract           | Base Sepolia (84532)                         |
| ------------------ | -------------------------------------------- |
| DataRegistry       | `0x0F3eb0E62CF610dbaC6B3aD4Bf4cE38Ab50EBCC5` |
| SettlementRegistry | `0x61A5A195B54F57ada786Ba6689CdB04553cf7fBc` |
| Admin (wallet)     | `0x7b16387C5A8c514880E48bcacd52782FCF9Da936` |
| RPC                | `https://sepolia.base.org`                   |

## Build and test

```sh
cd solidity
forge build
forge test
```

Needs [Foundry](https://getfoundry.sh) and [Node.js](https://nodejs.org). The libraries are git submodules under `solidity/lib/`; after a fresh clone run `git submodule update --init --recursive`. OpenZeppelin Contracts (v5.7.0) is the copy inside `openzeppelin-contracts-upgradeable`, which is how the [OpenZeppelin Foundry Upgrades](https://docs.openzeppelin.com/upgrades-plugins/foundry/foundry-upgrades) plugin is set up.

Node.js is for that plugin: it checks upgrade safety by running `npx @openzeppelin/upgrades-core`, which is why `foundry.toml` turns on `ffi`. One test, `UpgradeSafety`, runs the check on every contract, and compares its storage with the build of that contract that is live (`solidity/deployed/`), so the first `forge test` needs internet access to download that npm package. The check needs a full build so if it fails with "not from a full compilation", run `forge clean` and try again.

USDC and Semaphore are mocks. Every test deploys its contracts behind a proxy, as the deploy script does, and each suite checks that only the admin can upgrade.

**The tests never touch a real network.** `forge test` runs every test on a local chain that Forge simulates in memory. The contracts are deployed there, the ETH and tokens the tests use are made up (`vm.deal`, the mocks), and the chain is thrown away when the test ends. Nothing is deployed to Base Sepolia or any other network, and no test ETH is spent. The only commands that send real transactions are scripts run with `--broadcast` (see *Deploy and upgrade*).

## Generate ABI

```sh
(cd solidity && forge inspect src/DataRegistry.sol:DataRegistry abi --json)
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

| What                                  | Command (add `--rpc-url <rpc> --account <keystore> --sender <admin> --broadcast`) |
| ------------------------------------- | --------------------------------------------------------------------------------- |
| Upgrade one contract only             | `forge script script/Upgrade.s.sol --force --sig "upgrade(string)" DataRegistry`  |
| Rotate the admin of every registry    | `forge script script/RotateAdmin.s.sol --sig "run(address)" <new admin>`          |
| First deployment on a new chain       | `forge script script/Deploy.s.sol --force --sig "all()"` (see *First deployment*) |
| Check `deployed/` is the live code    | `forge script script/Upgrade.s.sol --sig "check()" --rpc-url <rpc>` (no signer)   |

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

Each registry keeps its own admin. `RotateAdmin.s.sol` moves every deployed one at once, and first checks that they all still have the admin it records for the chain, so they cannot quietly drift apart. It refuses the zero address. After it runs, update the address it records.

### How an upgrade works

An upgrade replaces the code behind a proxy (`upgradeToAndCall`, admin-only). The address and all state stay, so nothing is migrated or repointed. If the ABI changed, clients need the new ABI.

1. **Edit the contract in place** (e.g. `src/DataRegistry.sol`). `forge test` checks it against the builds of the live versions, committed under `deployed/<chain id>/<Contract>/<implementation address>/`: the `UpgradeSafety` test fails if a storage slot moved, changed type or disappeared.
2. **Run the upgrade** (*Commands*), once per chain.

The script finds each proxy and its source in `Deployments.sol`. It compares the code in `src/` with the live code, ignoring comments, to decide what is out of date. Before upgrading, it confirms that the build in `deployed/` is the live code, and the OpenZeppelin plugin checks the new code's storage against it. With `--broadcast` it writes the new version's build next to the live one, and removes the one before. Commit it with the broadcast log: it is what the next upgrade is checked against.

Between merging a change and running its upgrade, `src/` is ahead of the chain. `deployed/` is what says which code is live.

**Storage is append-only.** The proxy keeps its storage, so the new code must read every existing slot the way the old code wrote it:

- Add state variables after the last one. Add struct fields at the end of the struct (a struct that is only ever a mapping value can grow).
- Never reorder, retype or remove a state variable or a struct field, and do not change the order of the contracts a registry inherits from.
- A constructor or an initial value on a state variable never reaches the proxy. New state that needs a starting value gets a `reinitializer(n)` function. Pass the call to it as a second argument and it runs in the upgrade transaction: `--sig "upgrade(string,bytes)" DataRegistry $(cast calldata "initializeV2()")`.

The plugin enforces the first two, and also refuses constructors, `selfdestruct` and `delegatecall` in a new version. A change that cannot keep the layout must be a full redeploy.

The contracts inherit OpenZeppelin's upgradeable variants (`EIP712Upgradeable`), which keep their state in namespaced storage and set it in `initialize`, so the plugin needs no exemption for any of them.

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

| `--sig`                  | Deploys              |
| ------------------------ | -------------------- |
| `"all()"`                | Every registry       |
| `"dataRegistry()"`       | A DataRegistry       |
| `"settlementRegistry()"` | A SettlementRegistry |

Parameters are environment variables, with defaults in `solidity/.env.example` (Forge reads `solidity/.env`):

- `ADMIN_ADDR`: required.
- `USDC_ADDR`, `SEMAPHORE_ADDR`: default to Base Sepolia's; required on any other chain.

Afterwards:

1. Record each printed proxy address in `script/Deployments.sol`. The other scripts find the contracts there.
2. Commit the builds the script wrote under `deployed/<chain id>/`, along with the broadcast log. The first upgrade is checked against them. `UpgradeSafety` fails while the builds and `Deployments.sol` disagree.
3. Add the admin to `script/RotateAdmin.s.sol` and the chain to *Deployed* above.

## Architecture

```
  Publisher ── update / updateBySig ──▶ DataRegistry        (P, keccak(repo)) → (pos, head)
               own repos only                                update log: MMR peaks

  Buyer ── register(terms, sig, pay) ──▶ SettlementRegistry  USDC split publisher / referrer
       ── settle(proof, reader)                               Semaphore group per subject
  Access worker ── canRead(reader, P, repo, key)
```

## DataRegistry

The head of every repo, and the update log.

- `update(repo, epoch, parent, root, car)`: moves the sender's `repo` from `parent` to the commit `(epoch, parent, root, repo, car)`, whose head the contract computes (`commitHead`): the sha256 digest of the commit's dag-cbor block. Reverts `StaleStateRoot` unless `parent` is the head, and `EpochOutOfWindow` unless `epoch` is within `WINDOW` (24) one-hour epochs of `currentEpoch()`. Emits `Updated(publisher, repo_id, repo, pos, parent, head)`.
- `updateBySig(publisher, repo, epoch, parent, root, car, signature)`: the same, authorized by the publisher's EIP-712 `Update` signature (or ERC-1271 for a contract wallet), so anyone may submit it. The parent check stops replays.
- The update log is a Merkle mountain range kept as `peaks` and `logLength`; `logRoot()` computes its root. Leaf `keccak256(abi.encode("leaf", publisher, repo_id, pos, head, timestamp))`.
- Views: `getHead(publisher, repo_id) → (pos, head)`, `repoIds(publisher, i)`, `repoCount(publisher)`, `commitHead`, `currentEpoch`, `domainSeparator`, `admin`.
- `initialize(admin)`.

## SettlementRegistry

Sells read access to a *subject* `(publisher, repo, key)`: `repo` is `keccak256` of the repo's name, and key zero is the whole repo. Prices are terms the publisher signs off-chain.

- `register(terms, signature, commitment, referrer, salt, payment)`: checks the publisher's EIP-712 `Terms(publisher, repo, key, price, shareBps, generation, deadline)` (or ERC-1271), takes `price` in USDC by ERC-3009 `receiveWithAuthorization` with nonce `registerNonce(subject, commitment, referrer, salt)`, pays the referrer `shareBps` unless it is denied or is the publisher, and the publisher the rest, and adds the Semaphore `commitment` to the subject's group. Free subjects move no money.
- `settle(publisher, repo, key, proof, reader)`: a Semaphore proof of membership in the subject's group, scoped to the subject, with `reader` as its message. One settle per payment.
- `canRead(reader, publisher, repo, key)`: true if the reader settled the record or the whole repo, and neither is disabled. What the access worker reads.
- Publisher: `raiseGeneration(repo)` voids every older terms for the repo; `setDenied(referrer, bool)`; `setDisabled(publisher, repo, key, bool)` (publisher or admin).
- Views: `subjectOf`, `registerNonce`, `hashTerms`, `generationOf`, `isDenied`, `isDisabled`, `groupOf`, `isRegistered`, `isSettled`, `usdc`, `semaphore`, `admin`.
- `initialize(admin, usdc, semaphore)`.
