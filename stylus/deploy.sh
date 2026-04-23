#!/usr/bin/env bash
# Deploy the Fangorn contracts (Settlement, Schema, DataSource) to an EVM chain
# and wire them together. Idempotent: if an address already exists in the
# artifacts file, that step is skipped.
#
# Usage:
#   export PRIVATE_KEY=0x...
#   ./deploy.sh                   # deploys to arbitrum-sepolia by default
#   ./deploy.sh --network mainnet # override
#   ./deploy.sh --fresh           # delete existing artifacts and redeploy everything
#
# Requires: cargo-stylus, cast (from foundry), jq

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

NETWORK="${NETWORK:-arbitrum-sepolia}"
FRESH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --network) NETWORK="$2"; shift 2 ;;
        --fresh)   FRESH=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Network-specific settings
case "$NETWORK" in
    arbitrum-sepolia)
        RPC_URL="https://sepolia-rollup.arbitrum.io/rpc"
        ADMIN="0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6"
        USDC="0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
        SEMAPHORE="0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D"
        MAX_FEE_GWEI="0.1"
        ;;
    *)
        echo "unknown network: $NETWORK" >&2
        exit 1
        ;;
esac

ARTIFACTS_FILE="deployments/${NETWORK}.json"
mkdir -p "$(dirname "$ARTIFACTS_FILE")"

if [[ "$FRESH" == "1" ]]; then
    rm -f "$ARTIFACTS_FILE"
fi

if [[ ! -f "$ARTIFACTS_FILE" ]]; then
    echo "{}" > "$ARTIFACTS_FILE"
fi

: "${PRIVATE_KEY:?PRIVATE_KEY env var required}"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Read an address from the artifacts file; empty string if not present.
read_addr() {
    local key="$1"
    jq -r --arg k "$key" '.[$k] // ""' "$ARTIFACTS_FILE"
}

# Write an address to the artifacts file.
write_addr() {
    local key="$1"
    local value="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$ARTIFACTS_FILE" > "$tmp"
    mv "$tmp" "$ARTIFACTS_FILE"
}

# Deploy a contract from a subdirectory. Echoes the deployed address.
# Skips if artifact already exists.
deploy_contract() {
    local key="$1"
    local dir="$2"
    shift 2
    local constructor_args=("$@")

    local existing
    existing=$(read_addr "$key")
    if [[ -n "$existing" ]]; then
        echo "  ✓ $key already at $existing (skipping)" >&2
        echo "$existing"
        return
    fi

    echo "  → deploying $key from $dir ..." >&2
    local output
    output=$(cd "$dir" && cargo stylus deploy \
        --private-key "$PRIVATE_KEY" \
        --endpoint "$RPC_URL" \
        --max-fee-per-gas-gwei "$MAX_FEE_GWEI" \
        --constructor-args "${constructor_args[@]}" \
        2>&1)

    # cargo-stylus prints the deployed address; grab the last 0x-prefixed 40-hex match
    local addr
    addr=$(echo "$output" | grep -iE 'deployed (code )?(to|at)' | grep -oE '0x[a-fA-F0-9]{40}' | head -1)
    if [[ -z "$addr" ]]; then
        echo "could not find deployed address in output:" >&2
        echo "$output" >&2
        exit 1
    fi

    write_addr "$key" "$addr"
    echo "  ✓ $key deployed at $addr" >&2
    echo "$addr"
}

check_wiring() {
    local label="$1"
    local contract="$2"
    local signature="$3"
    local expected="$4"

    local actual
    actual=$(cast call "$contract" "$signature" --rpc-url "$RPC_URL" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    expected=$(echo "$expected" | tr '[:upper:]' '[:lower:]')

    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $label" >&2
    else
        echo "  ✗ $label: expected $expected, got $actual" >&2
        exit 1
    fi
}

# Send a tx, waiting for inclusion. No-op if the "check" call already passes.
ensure_tx() {
    local label="$1"
    local contract="$2"
    local write_sig="$3"
    local write_args="$4"
    local check_sig="$5"
    local expected="$6"

    local actual
    actual=$(cast call "$contract" "$check_sig" --rpc-url "$RPC_URL" 2>&1 \
        | grep -oE '[a-f0-9]{40}$' | tr '[:upper:]' '[:lower:]' || echo "")
    expected=$(echo "$expected" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')

    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $label already configured (skipping)" >&2
        return
    fi

    echo "  → $label ..." >&2
    # shellcheck disable=SC2086
    cast send "$contract" "$write_sig" $write_args \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" > /dev/null
    echo "  ✓ $label" >&2
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "Deploying Fangorn to $NETWORK"
echo "  admin:     $ADMIN"
echo "  usdc:      $USDC"
echo "  semaphore: $SEMAPHORE"
echo "  artifacts: $ARTIFACTS_FILE"
echo

# echo "0/5 SemaphoreAdapter"
# ADAPTER=$(deploy_contract adapter ./semaphore_adapter "$SEMAPHORE")

echo "1/5 SettlementRegistry"
SETTLEMENT=$(deploy_contract settlement ./SettlementRegistry \
    "$ADMIN" "$USDC" "$ADAPTER")

echo "2/5 SchemaRegistry"
SCHEMA=$(deploy_contract schema ./SchemaRegistry "$ADMIN")

echo "3/5 DatasourceRegistry"
DATASOURCE=$(deploy_contract datasource ./DatasourceRegistry "$SCHEMA" "$SETTLEMENT")

echo "4/5 wire: SchemaRegistry -> DatasourceRegistry"
ensure_tx "set data source registry in schema registry" \
    "$SCHEMA" \
    "setDataSourceRegistry(address)" "$DATASOURCE" \
    "getDataSourceRegistry()(address)" "$DATASOURCE"

echo "5/5 wire: SettlementRegistry authorizes DatasourceRegistry"
# No getter for authorized_registries; we just send. This step isn't idempotent
# but rerunning is harmless (just sets the same bool true).
echo "  → authorizing data source registry in settlement registry ..." >&2
cast send "$SETTLEMENT" \
    "setRegistry(address,bool)" "$DATASOURCE" true \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" > /dev/null
echo "  ✓ authorized" >&2

# ── Final sanity checks ───────────────────────────────────────────────────────

echo
# echo "Verifying wiring..."
# check_wiring "schema.getAdmin == $ADMIN" \
#     "$SCHEMA" "getAdmin()(address)" "$ADMIN"
# check_wiring "schema.getDatasourceRegistry == $DATASOURCE" \
#     "$SCHEMA" "getDatasourceRegistry()(address)" "$DATASOURCE"

echo
echo "Deployment complete. Addresses saved to $ARTIFACTS_FILE:"
jq . "$ARTIFACTS_FILE"