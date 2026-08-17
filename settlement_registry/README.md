# SettlementRegistry

An [Arbitrum Stylus](https://docs.arbitrum.io/stylus/stylus-gentle-introduction)
(Rust → WASM) contract for **anonymous paid access to a resource**. A publisher lists a
resource at a price; a buyer pays in USDC and joins that resource's
[Semaphore](https://semaphore.pse.dev/) group; later, the buyer proves membership
without revealing which buyer they are, and the contract records access for a stealth
address that is not linkable to the payment.

Standalone: it is not part of the DataRegistry register/publish flow, and `deploy.sh`
does not touch it.

> **Status: v2, unaudited, testnet only.** v2 is a security rewrite — the ABI is not
> compatible with v1 and every client needs the changes in
> [Client migration](#client-migration). See [What changed in v2](#what-changed-in-v2).

## How a sale works

1. **List.** The publisher calls `createResource(uid, price, uri)`. The contract derives
   `resourceId = keccak(publisher ++ uid)`, creates a Semaphore group *for that
   resource*, and stores owner, price, URI and group id. Returns the id.
2. **Pay.** The buyer calls `register(resourceId, identityCommitment, from, amount, …)`
   with a USDC `transferWithAuthorization` (EIP-3009, gasless permit). The contract pays
   `resourceOwners[resourceId]` — read from storage, never from an argument — and adds
   `identityCommitment` to that resource's group.
3. **Prove.** The buyer calls `settle(resourceId, stealthAddress, …proof)`. The contract
   verifies the Semaphore proof **against that resource's group**, with the resourceId as
   the proof scope, burns the nullifier, and records `settlements[(stealth, resource)]`.
4. **Access.** The off-chain gate (the access worker) reads `isSettled(stealth, resource)`
   — and should read [`isDisabled`](#takedown-set_disabled) alongside it — before
   releasing the decryption key.

Steps 2 and 3 are unlinkable: the payment names the buyer's wallet, the settlement names
a stealth address, and the ZK proof shows only that *some* member of the group is behind
it.

## What changed in v2

v1 kept **one Semaphore group for the entire registry**. Three defects followed, each
independently fatal:

| # | v1 defect | v2 |
|---|---|---|
| 1 | `settle` verified group membership and nothing else, so paying any publisher once entitled the payer to **every resource in the registry, forever**. | One group per resource. Membership in R's group *is* "paid for R". |
| 2 | `createResource` was unauthenticated with a caller-set price, so anyone could mint a free resource, register against it, and land in that same global group — a total paywall bypass for the cost of gas. | Groups are per-resource, so a free resource unlocks only itself. |
| 3 | `register` took the payment recipient as an argument and checked only the *amount*, so a buyer could pay themselves and still join the group. | No recipient argument; the owner is read from storage. |

v2 also derives the resourceId instead of accepting it (anti-squatting), drops the
phantom seed member v1 inserted into every group, skips the transfer for zero-priced
resources, removes `#[payable]` from `register`, and adds
[`setDisabled`](#takedown-set_disabled).

The full rationale, including the privacy trade, is in the module docs at the top of
[`src/lib.rs`](src/lib.rs).

### The privacy trade, stated plainly

Per-resource groups shrink the anonymity set from "every buyer the registry has ever
had" to "the buyers of this resource." A file with three sales offers almost no
anonymity. That is the honest cost of correctness, and it is the right trade — an
entitlement nobody paid for is not privacy, it is a broken paywall.

If a larger anonymity set matters more than per-file pricing, the alternative worth
exploring is **one group per publisher**: buy anything from a publisher, unlock their
catalog. Same code shape, one line different in `createResource`, and a different
product.

## resourceId derivation

```
resourceId = keccak256(abi.encodePacked(publisher, uid))    // 20-byte address ++ 32-byte uid
```

The contract derives it from `msg.sender`, so a resourceId cannot be squatted or
front-run: an id nobody can produce without the publisher's address is an id nobody can
steal. v1 accepted the id as an argument, which made the id space first-come — anyone
watching the mempool could claim a publisher's id, set their own price and URI, and
collect the payments while the real publisher's `createResource` reverted forever.

Clients must match this exactly. In viem:

```js
import { encodePacked, keccak256 } from "viem";
const resourceId = keccak256(encodePacked(["address", "bytes32"], [publisher, uid]));
```

`resourceIdFor(publisher, uid)` is exposed as a view so the two derivations can be
diffed rather than trusted.

## State

| Field | Type | Meaning |
|-------|------|---------|
| `usdc_address` | `address` | The ERC-20 payments settle in (USDC, 6 decimals). |
| `semaphore_address` | `address` | Semaphore deployment used for groups and proofs. |
| `admin` | `address` | Takedown authority. **May be zero** — see below. |
| `resource_owners` | `bytes32 → address` | Publisher; also the payment recipient. |
| `resource_price` | `bytes32 → uint256` | Price in USDC base units. Zero means free. |
| `resource_uris` | `bytes32 → string` | Pointer to the content descriptor. |
| `resource_hooks` | `bytes32 → address` | Optional `afterSettle` callback. |
| `resource_groups` | `bytes32 → uint256` | **The resource's own Semaphore group.** |
| `resource_disabled` | `bytes32 → bool` | Takedown flag. |
| `registrations` | `keccak(resource ++ commitment) → bool` | Double-payment guard. |
| `nullifiers` | `uint256 → bool` | Spent Semaphore nullifiers. |
| `settlements` | `keccak(stealth ++ resource) → bool` | What the access gate reads. |

## Interface

Stylus exposes Rust `snake_case` as **camelCase** in the ABI — calling the snake_case
selector reverts. This bites every new caller.

**Publisher**

- `createResource(bytes32 uid, uint256 price, string uri) → bytes32 resourceId`
- `updatePrice(bytes32 resourceId, uint256 price)` — owner only
- `registerHook(bytes32 resourceId, address hook)` — owner only
- `setDisabled(bytes32 resourceId, bool disabled)` — owner **or** admin

**Buyer**

- `register(bytes32 resourceId, uint256 identityCommitment, address from, uint256 amount,
  uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s)`
- `settle(bytes32 resourceId, address stealthAddress, uint256 merkleTreeDepth,
  uint256 merkleTreeRoot, uint256 nullifier, uint256 message, uint256[8] points,
  bytes hookData)`

**Admin**

- `setAdmin(address newAdmin)` — pass the zero address to renounce permanently

**Views** — `resourceIdFor`, `isSettled`, `isRegistered`, `isDisabled`, `getPrice`,
`getGroupId`, `getOwner`, `getUri`, `getAdmin`, `getUsdc`, `getSemaphore`

**Errors** — `AlreadyRegistered`, `AlreadySettled`, `IncorrectPaymentAmount`,
`TransferFailed`, `VerificationFailed`, `NotResourceOwner`, `ResourceNotFound`,
`HookFailed`, `SemaphoreCallFailed`, `ResourceIsDisabled`, `NotAdmin`

## Takedown: `setDisabled`

```solidity
function setDisabled(bytes32 resourceId, bool disabled) external;   // owner or admin
function isDisabled(bytes32 resourceId) external view returns (bool);
```

Disabling blocks **new** `register` and **new** `settle` calls for that resource. It
deliberately does **not** un-settle existing buyers: `isSettled` stays true, because a
settlement that happened is a historical fact and the chain is not the place to pretend
otherwise. Stopping an already-settled buyer from fetching the bytes is the access
gate's job — the gate must read `isDisabled` before releasing a key, and today it does
not.

This flag exists because takedown had no on-chain representation at all, which is the
on-chain half of the gap described in `sond3r/COMPLIANCE.md` §3. It is the newest and
least-settled part of the contract.

### Notes to explore

Roughly in the order they should be resolved.

**1. An admin takedown can be reverted by the publisher.** `setDisabled` accepts owner
*or* admin for both directions, so a publisher can immediately re-enable a resource an
admin just pulled. That is a hole, not a preference. Options: record `disabled_by` and
require equal-or-greater authority to re-enable; or make admin disables one-way and
recoverable only by the admin; or split into `disable` (owner or admin) and `enable`
(constrained). Decide before mainnet.

**2. Who holds `admin`?** A single EOA is one compromised key and one subpoena target
away from arbitrary censorship of the registry. A multisig, a timelock, or an
arbitration contract are all more defensible. `Address::ZERO` is a real option too —
it means only publishers can take their own content down, which is a coherent stance
for a credibly-neutral registry and an untenable one for a US-operated platform that
needs a DMCA response path. This is a product and legal decision, not a technical one.

**3. Publisher consent.** Right now an admin can disable any resource, including those
of publishers who never agreed to that. Worth exploring: an opt-in flag set at
`createResource` (`admin_can_disable: bool`), so the takedown authority is something a
publisher accepts when listing rather than something imposed. It makes the platform's
offer explicit and it is visible on-chain.

**4. Granularity and mass incidents.** Takedown is per-resource. A notice naming 400
files is 400 transactions. There is also no registry-wide pause, so a live exploit has
no stop button. Worth exploring: `setDisabledMany(bytes32[] ids, bool)`, a per-publisher
disable, and a global pause guarded by the same authority question as (2).

**5. Evidence.** `ResourceDisabled(resourceId, disabled, by)` records who and when but
not *why*. Safe-harbor compliance is largely a matter of proving you acted expeditiously
on a specific notice — consider adding a `bytes32 reason` or an off-chain notice id to
the event so the on-chain log lines up with the takedown ledger.

**6. Refunds.** Payments go straight from buyer to publisher; the contract never holds
funds, so there is nothing to refund from. A buyer who paid and is later cut off by a
takedown has no on-chain remedy. That is a policy question with a contract consequence —
if refunds are ever promised, the money has to stop flowing directly.

**7. Scope of the block.** Disabling currently blocks `register` and `settle` but not
`updatePrice` or `registerHook`. Probably right (a disabled resource is not a frozen
one), but say so deliberately.

**8. Cross-contract suspension.** The DataRegistry already has publisher `suspend`.
Should a suspended publisher's resources be treated as disabled automatically? It would
mean a cross-contract read on the `settle` hot path — real gas for a rare case. Probably
better handled by the admin disabling in bulk, which is (4).

**9. Gate wiring and latency.** Once the worker reads `isDisabled`, decide how it caches
that read. A cache makes takedown slow; no cache puts an RPC call in the path of every
access. Neither is obviously right, and "expeditiously" is the standard being measured
against.

## Tests

```sh
cargo test --manifest-path settlement_registry/Cargo.toml
```

44 tests, all `TestVM`-based, no network. Notably including the v1 exploits as
regression tests: `a_free_resource_does_not_unlock_someone_elses`,
`register_never_pays_the_buyer`, `create_resource_cannot_be_squatted`, and
`same_buyer_can_pay_for_a_second_resource` (which v1 structurally could not do).

**How the important assertions work.** `TestVM` returns `Ok(empty)` for any call that is
not mocked, so it can never show Semaphore *rejecting* a proof — a naive happy-path test
proves nothing about the group wiring. Instead the properties are pinned by calldata:
mock the exact call the contract is supposed to emit, make that mock revert, and assert
the specific error propagates. If the contract built anything else — wrong group, wrong
recipient, wrong scope — the mock never matches, the call succeeds, and the assertion
fails. The `_pins_` and `never_` tests come in pairs, one for each direction.

The limit of this technique, stated so nobody over-reads the green: **it verifies that
the contract asks Semaphore the right question, not that Semaphore gives the right
answer.** Proof soundness needs an integration test against a real Semaphore deployment,
and the whole thing needs an audit before mainnet.

## Deploy (Arbitrum Sepolia)

The constructor takes **three** arguments in v2 — the admin is new.

```sh
USDC=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
SEMAPHORE=0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
ADMIN=0x0000000000000000000000000000000000000000   # zero = no takedown authority

cargo stylus deploy \
    --private-key <private_key> \
    --endpoint https://sepolia-rollup.arbitrum.io/rpc \
    --max-fee-per-gas-gwei 0.1 \
    --constructor-args $USDC $SEMAPHORE $ADMIN
```

Generate the ABI with `cargo stylus export-abi --json` from inside this crate.

## Client migration

v2 is an ABI break. Every one of these is required:

1. **resourceId derivation** moves from any client-side scheme to
   `keccak(publisher ++ uid)`. In sond3r this orphans everything already published:
   worker chunk keys, `/c/<resourceId>` permalinks, shard rows and `.flix.json`
   pointers all key off it.
2. **`register` loses its `to` argument.** Update the caller and the facilitator.
3. **Entitlement checks become per-resource.** "Has this buyer paid?" is now "is this
   commitment in resource R's group" — filter `MemberRegistered` by `resourceId` rather
   than rebuilding one global group. It is cheaper, too.
4. **Derive a per-resource buyer identity** (e.g. sign `fangorn:identity:v1:<resourceId>`)
   so the same commitment never appears as a leaf in two groups.
5. **`createResource` takes a uid, not an id,** and returns the id.
6. **The access gate should read `isDisabled`** before releasing a key, or the takedown
   flag means nothing.

## Known gaps

- Not audited. `TestVM` proves wiring, not zero-knowledge soundness.
- No registry-wide pause; see the takedown notes (4).
- Nullifiers are a single global set. Semaphore scopes nullifiers per (identity,
  resource), so a collision across resources implies a forgery and is rejected — this is
  intentional and tested, but it is a coupling worth remembering.
- A price change takes effect immediately, so an authorization signed against the old
  price reverts rather than under- or over-paying. Safe, but it means a publisher can
  invalidate in-flight purchases at will.
