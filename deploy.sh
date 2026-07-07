#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Deploys the bucket system to Arbitrum Sepolia.
#
#   Bucket (Stylus)            – shared implementation; clones delegatecall it
#   PublisherRegistry (Stylus) – only user-facing contract
#   BucketFactory (Solidity)   – ERC-1167 clone factory
#
# Order (breaks the registry<->factory cycle):
#   1. deploy Bucket impl
#   2. deploy PublisherRegistry with factory = 0x0 (unknown yet)
#   3. deploy BucketFactory(bucketImpl, registry)
#   4. registry.set_factory(factory)   ← admin wires it in
# ==============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
PRIVATE_KEY="${PRIVATE_KEY:-0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
MAX_FEE="${MAX_FEE:-0.1}"

ADMIN_ADDR="${ADMIN_ADDR:-0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6}"
# Registration fee in wei. 0 = free registration for the MVP.
REGISTRATION_FEE="${REGISTRATION_FEE:-0}"

ZERO_ADDR="0x0000000000000000000000000000000000000000"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

# ── Helpers (diagnostics to stderr; only the address goes to stdout) ──────────
log_step() {
    echo -e "\n==================================================" >&2
    echo -e "🚀 $1" >&2
    echo -e "==================================================" >&2
}

cast_call() { cast call "$1" "$2" --rpc-url "$RPC_ENDPOINT"; }

cast_send() {
    local contract="$1" signature="$2"; shift 2
    cast send "$contract" "$signature" "$@" \
        --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" > /dev/null
}

# Deploy a Stylus contract. Extra args become --constructor-args.
deploy_stylus() {
    local dir="$1"; shift
    echo "Deploying Stylus contract from $dir..." >&2
    if [ "$#" -gt 0 ]; then
        (cd "$dir" && cargo stylus deploy \
            --private-key "$PRIVATE_KEY" --endpoint "$RPC_ENDPOINT" \
            --max-fee-per-gas-gwei "$MAX_FEE" \
            --constructor-args "$@") > "$LOG_FILE" 2>&1
    else
        (cd "$dir" && cargo stylus deploy \
            --private-key "$PRIVATE_KEY" --endpoint "$RPC_ENDPOINT" \
            --max-fee-per-gas-gwei "$MAX_FEE") > "$LOG_FILE" 2>&1
    fi
    cat "$LOG_FILE" >&2
    local address
    address=$(grep -i "deployed code at address:" "$LOG_FILE" \
        | grep -oE '0x[a-fA-F0-9]{40}' | head -n1 | tr -d '[:space:]')
    [ -n "$address" ] || { echo "❌ No address in logs." >&2; exit 1; }
    echo "✅ Deployed: $address" >&2
    echo "$address"
}

# Deploy a Solidity contract via forge create. Extra args become constructor args.
deploy_forge() {
    local root="$1" target="$2"; shift 2
    echo "Deploying Solidity contract $target..." >&2
    forge create --root "$root" "$target" \
        --private-key "$PRIVATE_KEY" --rpc-url "$RPC_ENDPOINT" \
        --broadcast --constructor-args "$@" > "$LOG_FILE" 2>&1
    cat "$LOG_FILE" >&2
    local address
    address=$(grep -i "Deployed to:" "$LOG_FILE" \
        | grep -oE '0x[a-fA-F0-9]{40}' | head -n1 | tr -d '[:space:]')
    [ -n "$address" ] || { echo "❌ No address in logs." >&2; exit 1; }
    echo "✅ Deployed: $address" >&2
    echo "$address"
}

# ── Deployment sequence ───────────────────────────────────────────────────────
echo "=========================================" >&2
echo " Deploying bucket system to Arbitrum Sepolia" >&2
echo "=========================================" >&2

# 1. Bucket implementation (no constructor; clones call initialize()).
log_step "[1/4] Deploying Bucket implementation"
BUCKET_IMPL=$(deploy_stylus "$SCRIPT_DIR/bucket")

# 2. PublisherRegistry — init(admin, factory, registration_fee). Factory not
#    known yet, so pass the zero address and wire it in at step 4.
log_step "[2/4] Deploying PublisherRegistry"
REGISTRY=$(deploy_stylus "$SCRIPT_DIR/publisher_registry" \
    "$ADMIN_ADDR" "$ZERO_ADDR" "$REGISTRATION_FEE")

echo "Verifying registry admin..." >&2
cast_call "$REGISTRY" "admin()(address)"

# 3. BucketFactory(bucketImplementation, publisherRegistry).
log_step "[3/4] Deploying BucketFactory"
FACTORY=$(deploy_forge "$SCRIPT_DIR/bucket_factory" \
    "src/BucketFactory.sol:BucketFactory" "$BUCKET_IMPL" "$REGISTRY")

# 4. Wire the factory into the registry (admin-only).
log_step "[4/4] Registering factory in PublisherRegistry"
cast_send "$REGISTRY" "setFactory(address)" "$FACTORY"

echo "Verifying factory binding..." >&2
cast_call "$REGISTRY" "factory()(address)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n=========================================" >&2
echo " 🎉 Deployment complete" >&2
echo "=========================================" >&2
echo "Bucket implementation: $BUCKET_IMPL" >&2
echo "PublisherRegistry:     $REGISTRY"    >&2
echo "BucketFactory:         $FACTORY"     >&2
echo "=========================================" >&2
