#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Deploys the Fangorn contracts to Arbitrum Sepolia.
#
#   DataRegistry (Stylus)         – publisher registration + state-root timeline;
#                                   pulls the registration fee in USDC.
#   SubscriptionRegistry (Stylus) – the paid storage subscription; pulls the
#                                   subscription fee in USDC and cross-calls
#                                   DataRegistry.isRegistered.
#
# Order (when deploying both):
#   1. deploy DataRegistry(admin, usdc, registration_fee)
#   2. deploy SubscriptionRegistry(admin, usdc, dataRegistry, subscription_fee)
#
# Runs interactively — asks whether to deploy both or a single contract — or preset
# TARGET=both|data-registry|subscription for non-interactive runs. Deploying ONLY the
# SubscriptionRegistry needs the address of an already-deployed DataRegistry to check
# registration against (DATA_REGISTRY_ADDR, else you're prompted).
# ==============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
PRIVATE_KEY="${PRIVATE_KEY:-0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
MAX_FEE="${MAX_FEE:-0.1}"

ADMIN_ADDR="${ADMIN_ADDR:-0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6}"
# Fees are in USDC base units (6 decimals). 0 = free.
REGISTRATION_FEE="${REGISTRATION_FEE:-0}"
SUBSCRIPTION_FEE="${SUBSCRIPTION_FEE:-0}"
# USDC token on Arbitrum Sepolia (both fees are paid in it).
USDC_ADDR="${USDC_ADDR:-0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d}"
# Only needed when deploying the SubscriptionRegistry ALONE: the already-deployed
# DataRegistry it checks registration against. Prompted if empty and required.
DATA_REGISTRY_ADDR="${DATA_REGISTRY_ADDR:-}"

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

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

# ── Choose what to deploy ─────────────────────────────────────────────────────
# TARGET may be preset (both|data-registry|subscription); otherwise ask.
TARGET="${TARGET:-}"
if [ -z "$TARGET" ]; then
    echo "What do you want to deploy?" >&2
    echo "  1) both  (DataRegistry, then SubscriptionRegistry wired to it)" >&2
    echo "  2) DataRegistry only" >&2
    echo "  3) SubscriptionRegistry only" >&2
    read -rp "Select [1/2/3]: " choice
    case "$choice" in
        1|both) TARGET="both" ;;
        2|data-registry|data_registry) TARGET="data-registry" ;;
        3|subscription|subscription-registry|subscription_registry) TARGET="subscription" ;;
        *) echo "❌ Unrecognized choice: '$choice' (want 1, 2, or 3)." >&2; exit 1 ;;
    esac
fi

echo "=========================================" >&2
echo " Deploying to Arbitrum Sepolia — target: $TARGET" >&2
echo "=========================================" >&2

DATA_REGISTRY=""
SUBSCRIPTION_REGISTRY=""

# DataRegistry (fresh) when deploying it or both.
if [ "$TARGET" = "both" ] || [ "$TARGET" = "data-registry" ]; then
    log_step "Deploying DataRegistry"
    DATA_REGISTRY=$(deploy_stylus "$SCRIPT_DIR/data_registry" \
        "$ADMIN_ADDR" "$USDC_ADDR" "$REGISTRATION_FEE")
    echo "Verifying registry admin..." >&2
    cast_call "$DATA_REGISTRY" "admin()(address)"
fi

# Subscription-only needs the address of an existing DataRegistry to point at — the
# one input not produced by this run. Ask for it if not already provided.
if [ "$TARGET" = "subscription" ]; then
    if ! is_address "$DATA_REGISTRY_ADDR"; then
        read -rp "Existing DataRegistry address the subscription checks against (0x…): " DATA_REGISTRY_ADDR
    fi
    is_address "$DATA_REGISTRY_ADDR" \
        || { echo "❌ Invalid DataRegistry address: '${DATA_REGISTRY_ADDR:-<empty>}'." >&2; exit 1; }
    DATA_REGISTRY="$DATA_REGISTRY_ADDR"
fi

# SubscriptionRegistry when deploying it or both (wired to $DATA_REGISTRY).
if [ "$TARGET" = "both" ] || [ "$TARGET" = "subscription" ]; then
    log_step "Deploying SubscriptionRegistry"
    SUBSCRIPTION_REGISTRY=$(deploy_stylus "$SCRIPT_DIR/subscription_registry" \
        "$ADMIN_ADDR" "$USDC_ADDR" "$DATA_REGISTRY" "$SUBSCRIPTION_FEE")
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n=========================================" >&2
echo " 🎉 Deployment complete" >&2
echo "=========================================" >&2
if [ -n "$DATA_REGISTRY" ]; then
    if [ "$TARGET" = "subscription" ]; then
        echo "DataRegistry (existing): $DATA_REGISTRY" >&2
    else
        echo "DataRegistry:            $DATA_REGISTRY" >&2
    fi
fi
[ -n "$SUBSCRIPTION_REGISTRY" ] && echo "SubscriptionRegistry:    $SUBSCRIPTION_REGISTRY" >&2
echo "=========================================" >&2
echo "Next: repoint fangorn/src/config.ts, websites/fangorn/.env.local," >&2
echo "      and webworker/pinata-url-provider/wrangler.toml at the address(es) above." >&2
