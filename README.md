# Bucket System

Publisher-owned storage buckets on Arbitrum. Each publisher registers once and gets their own **bucket** that they can publish to. A **bucket** is an isolated store for *schemas* and the *datasources* published against them.

## Architecture

```
                 register()            createBucket(owner)
   Publisher ───────────────▶ PublisherRegistry ───────────────▶ BucketFactory
   (user)                     (Stylus, sole                      (Solidity,
                               user-facing API)                   ERC-1167 factory)
                                     │                                  │
                                     │ forwards writes                  │ clone + initialize
                                     ▼                                  ▼
                                Publisher's Bucket  ◀── delegatecall ── Bucket clone
                                                                        │
                                                                        ▼
                                                              Bucket implementation
                                                                 (Stylus, shared)
```

- **Bucket** (`bucket/`, Stylus) — holds one publisher's schemas + datasources.
  Deployed once as a shared *implementation*; every publisher gets a cheap
  ERC-1167 clone that `delegatecall`s it but keeps isolated storage. Mutations
  are gated by `only_registry` — only the PublisherRegistry may write.
- **BucketFactory** (`bucket_factory/`, Solidity) — EIP-1167 minimal-proxy
  factory. `createBucket(owner)` clones the implementation and calls
  `initialize(owner, registry)`. Registry-only.
- **PublisherRegistry** (`publisher_registry/`, Stylus) — the only contract users
  touch. `register()` pays the fee and provisions a bucket; schema/datasource
  writes are forwarded to the caller's own bucket. Reads hit the bucket directly
  (look it up via `bucket_of(publisher)`).

### Why a Solidity factory + Stylus buckets

Stylus contracts cannot deploy other Stylus (WASM) contracts on-chain, and
Stylus has no proxy fallback. A Solidity EIP-1167 clone *can* `delegatecall`
into a Stylus implementation (identical storage layout across the VMs), so the
factory and proxies are Solidity while the logic stays in Stylus.

## Layout

| Path                  | Contract          | Toolchain     |
|-----------------------|-------------------|---------------|
| `bucket/`             | Bucket            | cargo stylus  |
| `publisher_registry/` | PublisherRegistry | cargo stylus  |
| `bucket_factory/`     | BucketFactory     | forge         |
| `deploy.sh`           | deployment script | bash          |

## Bucket API (per publisher)

Writes (registry-only): `register_schema`, `update_schema_agent`,
`delete_schema`, `publish`.
Reads: `get_schema`, `schema_exists`, `get`, `get_merkle_root`, `get_version`,
`get_name`, `resource_id`, `owner`, `registry`.

Schemas are keyed by `keccak256(name)`; datasources by `(schema, keccak256(name))`.
`publish` increments a version on every call (first publish = v1). A schema
cannot be deleted while datasources reference it.

## Build & test

```sh
# Stylus crates
cargo test --manifest-path bucket/Cargo.toml
cargo test --manifest-path publisher_registry/Cargo.toml

# Solidity factory
forge test --root bucket_factory
```

## Generate ABI

``` sh
cargo stylus export-abi --json
```

## Deploy (Arbitrum Sepolia)

```sh
bash deploy.sh
```

Deploys Bucket impl → PublisherRegistry → BucketFactory, then wires the factory
into the registry (the two reference each other, so the registry is deployed with
`factory = 0x0` and `setFactory` is called last).

Config via env vars (sensible defaults in the script): `PRIVATE_KEY`,
`RPC_ENDPOINT`, `MAX_FEE`, `ADMIN_ADDR`, `REGISTRATION_FEE` (wei; `0` = free).
Requires `cargo stylus`, `forge`, and `cast`.

## Status

MVP. Not audited. Live register→clone→publish flow is exercised on-chain, not in
unit tests — the Stylus TestVM can't deploy contracts or `delegatecall`.
