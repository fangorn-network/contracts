#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Deploys the DataRegistry to Arbitrum Sepolia.
#
#   1. deploy DataRegistry(admin, registration_fee)
#   2. register the default app namespace, so the SDK's out-of-the-box
#      appId("fangorn") — what the CLI uses — can be committed to immediately.
#      Namespaces are hierarchical (app:publisher:subspace) and commit_state_root
#      rejects an unregistered app_id, so without this every default-config
#      publish fails with AppNotFound.
# ==============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
PRIVATE_KEY="${PRIVATE_KEY:-0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
MAX_FEE="${MAX_FEE:-0.1}"

ADMIN_ADDR="${ADMIN_ADDR:-0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6}"
# Registration fee in wei. 0 = free registration for the MVP.
REGISTRATION_FEE="${REGISTRATION_FEE:-0}"
# The app namespace claimed at deploy time. Must match the SDK's default
# `appId("fangorn")` in fangorn/src/config.ts — keccak256 of the UTF-8 name,
# which is exactly what `cast keccak` computes.
DEFAULT_APP_NAME="${DEFAULT_APP_NAME:-fangorn}"

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

# Extra args after the signature become call arguments.
cast_call() {
    local contract="$1" signature="$2"; shift 2
    cast call "$contract" "$signature" "$@" --rpc-url "$RPC_ENDPOINT"
}

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

echo "=========================================" >&2
echo " Deploying to Arbitrum Sepolia" >&2
echo "=========================================" >&2

log_step "Deploying DataRegistry"
DATA_REGISTRY=$(deploy_stylus "$SCRIPT_DIR/data_registry" \
    "$ADMIN_ADDR" "$REGISTRATION_FEE")

echo "Verifying registry admin..." >&2
cast_call "$DATA_REGISTRY" "admin()(address)"

log_step "Registering default app namespace: $DEFAULT_APP_NAME"
APP_ID=$(cast keccak "$DEFAULT_APP_NAME")
echo "app_id = $APP_ID" >&2
cast_send "$DATA_REGISTRY" "registerApp(bytes32)" "$APP_ID"
echo "Verifying app owner..." >&2
cast_call "$DATA_REGISTRY" "getAppOwner(bytes32)(address)" "$APP_ID"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n=========================================" >&2
echo " 🎉 Deployment complete" >&2
echo "=========================================" >&2
echo "DataRegistry Contract Address: $DATA_REGISTRY" >&2
echo "Default app \"$DEFAULT_APP_NAME\": $APP_ID" >&2
echo "=========================================" >&2
echo >&2
echo "Set dataRegistryContractAddress in fangorn/src/config.ts to $DATA_REGISTRY" >&2
