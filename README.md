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

See [spec.md](docs/spec.md) for more information on each contract and the overal architecture. 

## Build and test

```sh
cd solidity
forge build
forge test
```

### Prerequisites

You must install [Foundry](https://getfoundry.sh) and [Node.js](https://nodejs.org). Both libraries are git submodules under `solidity/lib/`. After a fresh clone run `git submodule update --init --recursive`. OpenZeppelin Contracts (v5.7.0) is the copy inside `openzeppelin-contracts-upgradeable`, which is how the [OpenZeppelin Foundry Upgrades](https://docs.openzeppelin.com/upgrades-plugins/foundry/foundry-upgrades) plugin is set up.

## Generate ABI

```sh
forge inspect src/DataRegistry.sol:DataRegistry abi --json
```

## Deploy and upgrade

All contracts are upgradeable using an ERC-1967 proxy (UUPS).

### Commands

| What                                  | Command (add `--rpc-url <rpc> --account <keystore> --sender <admin> --broadcast`) |
| ------------------------------------- | --------------------------------------------------------------------------------- |
| Upgrade a contract             | `forge script script/Upgrade.s.sol --force --sig "upgrade(string)" DataRegistry`  |
| Deployment fresh proxy contracts       | `forge script script/Deploy.s.sol --force --sig "all()"` (see *First deployment*) |
| Update a contracts a deployed proxy points to    | `forge script script/Upgrade.s.sol --sig "check()" --rpc-url <rpc>` (no signer)   |

### Setup

Setup a Foundry keystore in order to sign transactions. Keys are encrypted and stored under `~/.foundry/keystores/<name>`. `<keystore>`.

```sh
cast wallet import admin-base --interactive   # paste the private key, then choose a password
cast wallet list                              # the names you have imported
cast wallet address --account admin-base      # the address behind it: pass it as --sender
```

> Pass `--ledger` instead of `--account` for a hardware wallet.

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


### Upgrading Contracts

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

