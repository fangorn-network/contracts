#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Deploys the Fangorn contracts to Arbitrum Sepolia.
#
#   AppRegistry (Stylus)          – app ids, per-app terms + join fees, per-app
#                                   publisher membership. Depends on nothing.
#   DataRegistry (Stylus)         – publisher registration + state-root timeline.
#                                   Cross-calls AppRegistry.isRegisteredForApp in
#                                   commit_state_root, so it deploys AFTER it.
#   SubscriptionRegistry (Stylus) – paid storage subscription; pulls USDC fee and
#                                   cross-calls DataRegistry.isRegistered.
#   SettlementRegistry (Stylus)   – ZK settlement registry with Semaphore & USDC auth.
#
# Order (when deploying all) — the dependency chain runs one way:
#   AppRegistry ◄── DataRegistry ◄── SubscriptionRegistry
#
#   1. deploy AppRegistry(admin)
#   2. register default app namespace ("fangorn") WITH its terms + join fee
#   3. deploy DataRegistry(admin, registration_fee, appRegistry)
#   4. deploy SubscriptionRegistry(admin, usdc, dataRegistry, subscription_fee)
#   5. deploy SettlementRegistry(usdc, semaphore, admin)
#
# NOTE ON REDEPLOYING DataRegistry: its `namespace_heads` mapping is every
# publisher's timeline head and does NOT survive a new deployment. Replay them
# with `seedNamespaceHead(app_id, publisher, subspace_id, root)` (admin-only, and
# fill-only — it refuses a slot that already holds a root) or every library
# published against the old address reads as empty.
#
# Runs interactively or non-interactively via TARGET environment variable:
#   TARGET=all|app-registry|data-registry|subscription|settlement
# ==============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
PRIVATE_KEY="${PRIVATE_KEY:-0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
MAX_FEE="${MAX_FEE:-0.1}"

ADMIN_ADDR="${ADMIN_ADDR:-0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6}"
REGISTRATION_FEE="${REGISTRATION_FEE:-0}"
DEFAULT_APP_NAME="${DEFAULT_APP_NAME:-fangorn}"
# The default app's publisher terms: sha256 of the terms document, and where it is
# served. An app with a zero terms hash cannot be joined, so this must be real
# before any publisher can register for it.
DEFAULT_APP_TERMS_HASH="${DEFAULT_APP_TERMS_HASH:-}"
DEFAULT_APP_TERMS_URI="${DEFAULT_APP_TERMS_URI:-https://fangorn.network/terms.html}"
DEFAULT_APP_JOIN_FEE="${DEFAULT_APP_JOIN_FEE:-0}"
SUBSCRIPTION_FEE="${SUBSCRIPTION_FEE:-0}"

# External Contract Dependencies
USDC_ADDR="${USDC_ADDR:-0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d}"
SEMAPHORE_ADDR="${SEMAPHORE_ADDR:-0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D}"

# Only needed when deploying SubscriptionRegistry ALONE
DATA_REGISTRY_ADDR="${DATA_REGISTRY_ADDR:-}"

ZERO_ADDR="0x0000000000000000000000000000000000000000"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────
log_step() {
    echo -e "\n==================================================" >&2
    echo -e "🚀 $1" >&2
    echo -e "==================================================" >&2
}

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

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

# ── Choose Target ─────────────────────────────────────────────────────────────
TARGET="${TARGET:-}"
if [ -z "$TARGET" ]; then
    echo "What do you want to deploy?" >&2
    echo "  1) all                   (AppRegistry, DataRegistry, SubscriptionRegistry, SettlementRegistry)" >&2
    echo "  2) DataRegistry only     (asks for an existing AppRegistry address)" >&2
    echo "  3) SubscriptionRegistry only" >&2
    echo "  4) SettlementRegistry only" >&2
    echo "  5) AppRegistry only" >&2
    read -rp "Select [1/2/3/4/5]: " choice
    case "$choice" in
        1|all|both) TARGET="all" ;;
        2|data-registry|data_registry) TARGET="data-registry" ;;
        5|app-registry|app_registry) TARGET="app-registry" ;;
        3|subscription|subscription-registry|subscription_registry) TARGET="subscription" ;;
        4|settlement|settlement-registry|settlement_registry) TARGET="settlement" ;;
        *) echo "❌ Unrecognized choice: '$choice' (want 1, 2, 3, or 4)." >&2; exit 1 ;;
    esac
fi

echo "=========================================" >&2
echo " Deploying to Arbitrum Sepolia — target: $TARGET" >&2
echo "=========================================" >&2

APP_REGISTRY=""
DATA_REGISTRY=""
SUBSCRIPTION_REGISTRY=""
SETTLEMENT_REGISTRY=""
APP_ID=""

# ── 1. AppRegistry ────────────────────────────────────────────────────────────
# First, because DataRegistry takes its address in the constructor.
if [ "$TARGET" = "all" ] || [ "$TARGET" = "app-registry" ]; then
    log_step "Deploying AppRegistry"
    APP_REGISTRY=$(deploy_stylus "$SCRIPT_DIR/app_registry" "$ADMIN_ADDR")
    echo "Verifying registry admin..." >&2
    cast_call "$APP_REGISTRY" "admin()(address)"

    log_step "Registering default app namespace: $DEFAULT_APP_NAME"
    APP_ID=$(cast keccak "$DEFAULT_APP_NAME")
    echo "app_id = $APP_ID" >&2
    # A zero terms hash leaves the app unjoinable, which reads on the website as
    # "registration is broken". Fail here instead, where the cause is obvious.
    if [ -z "$DEFAULT_APP_TERMS_HASH" ]; then
        echo "❌ DEFAULT_APP_TERMS_HASH is empty — an app with no terms cannot be joined." >&2
        echo "   Set it to the sha256 of the terms you serve at $DEFAULT_APP_TERMS_URI:" >&2
        echo "     DEFAULT_APP_TERMS_HASH=0x\$(sha256sum terms.html | cut -d' ' -f1)" >&2
        exit 1
    fi
    cast_send "$APP_REGISTRY" "registerApp(bytes32,bytes32,string,uint256)" \
        "$APP_ID" "$DEFAULT_APP_TERMS_HASH" "$DEFAULT_APP_TERMS_URI" "$DEFAULT_APP_JOIN_FEE"
    echo "Verifying app owner..." >&2
    cast_call "$APP_REGISTRY" "getAppOwner(bytes32)(address)" "$APP_ID"
fi

# Prompt for an existing AppRegistry if DataRegistry is being deployed alone.
if [ "$TARGET" = "data-registry" ]; then
    if ! is_address "$APP_REGISTRY_ADDR"; then
        read -rp "Existing AppRegistry address (0x…): " APP_REGISTRY_ADDR
    fi
    is_address "$APP_REGISTRY_ADDR" \
        || { echo "❌ Invalid AppRegistry address: '${APP_REGISTRY_ADDR:-<empty>}'." >&2; exit 1; }
    APP_REGISTRY="$APP_REGISTRY_ADDR"
fi

# ── 2. DataRegistry ───────────────────────────────────────────────────────────
if [ "$TARGET" = "all" ] || [ "$TARGET" = "data-registry" ]; then
    log_step "Deploying DataRegistry"
    DATA_REGISTRY=$(deploy_stylus "$SCRIPT_DIR/data_registry" \
        "$ADMIN_ADDR" "$REGISTRATION_FEE" "$APP_REGISTRY")
    echo "Verifying registry admin..." >&2
    cast_call "$DATA_REGISTRY" "admin()(address)"
    echo "Verifying it points at the AppRegistry..." >&2
    cast_call "$DATA_REGISTRY" "appRegistry()(address)"
fi

# Prompt for existing DataRegistry if Subscription-only
if [ "$TARGET" = "subscription" ]; then
    if ! is_address "$DATA_REGISTRY_ADDR"; then
        read -rp "Existing DataRegistry address for subscription check (0x…): " DATA_REGISTRY_ADDR
    fi
    is_address "$DATA_REGISTRY_ADDR" \
        || { echo "❌ Invalid DataRegistry address: '${DATA_REGISTRY_ADDR:-<empty>}'." >&2; exit 1; }
    DATA_REGISTRY="$DATA_REGISTRY_ADDR"
fi

# ── 3. SubscriptionRegistry ───────────────────────────────────────────────────
if [ "$TARGET" = "all" ] || [ "$TARGET" = "subscription" ]; then
    log_step "Deploying SubscriptionRegistry"
    SUBSCRIPTION_REGISTRY=$(deploy_stylus "$SCRIPT_DIR/subscription_registry" \
        "$ADMIN_ADDR" "$USDC_ADDR" "$DATA_REGISTRY" "$SUBSCRIPTION_FEE")
fi

# ── 4. SettlementRegistry ─────────────────────────────────────────────────────
if [ "$TARGET" = "all" ] || [ "$TARGET" = "settlement" ]; then
    log_step "Deploying SettlementRegistry"
    # Groups are per-resource now, created by createResource — there is no group
    # to verify at deploy time. The admin (takedown authority, may be the zero
    # address for a registry nobody can administer) is the new constructor arg.
    SETTLEMENT_REGISTRY=$(deploy_stylus "$SCRIPT_DIR/settlement_registry" \
        "$USDC_ADDR" "$SEMAPHORE_ADDR" "$ADMIN_ADDR")
    echo "Verifying settlement registry admin..." >&2
    cast_call "$SETTLEMENT_REGISTRY" "getAdmin()(address)"
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
[ -n "$APP_REGISTRY" ] && echo "AppRegistry:          $APP_REGISTRY" >&2
[ -n "$APP_ID" ] && echo "Default app \"$DEFAULT_APP_NAME\": $APP_ID" >&2
[ -n "$SUBSCRIPTION_REGISTRY" ] && echo "SubscriptionRegistry:    $SUBSCRIPTION_REGISTRY" >&2
[ -n "$SETTLEMENT_REGISTRY" ]   && echo "SettlementRegistry:      $SETTLEMENT_REGISTRY" >&2
echo "=========================================" >&2