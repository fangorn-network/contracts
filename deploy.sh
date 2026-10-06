#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Deploys the Fangorn contracts to Arbitrum Sepolia.
#
#   AppRegistry (Stylus)          – app ids, per-app terms + join fees, invitation-only
#                                   publisher membership, and the paid storage
#                                   subscription: claiming an app pulls the USDC fee.
#                                   Cross-calls DataRegistry.isRegistered when an app
#                                   is claimed or a publisher added.
#   DataRegistry (Stylus)         – publisher registration + state-root timeline.
#                                   Cross-calls AppRegistry.isRegisteredForApp in
#                                   commit_state_root.
#   SettlementRegistry (Stylus)   – ZK settlement registry with Semaphore & USDC auth.
#
# The two registries point at each other, so (when deploying all):
#
#   1. deploy AppRegistry(admin, usdc, subscription_fee, 0x0)      — unwired
#   2. deploy DataRegistry(admin, registration_fee, appRegistry)
#   3. AppRegistry.setDataRegistry(dataRegistry)
#   4. register the deployer in the DataRegistry, then claim the default app
#      ("fangorn") WITH its terms + join fee — this pays the subscription fee, so
#      the deployer approves USDC first
#   5. deploy SettlementRegistry(usdc, semaphore, admin)
#
# REDEPLOYING AppRegistry ALONE: DATA_REGISTRY_ADDR is required. The new AppRegistry
# is born pointing at it, and it is repointed at the new one (`setAppRegistry`,
# admin-only), keeping every namespace head. Apps and memberships do NOT carry over:
# each app is re-claimed (and paid for) and its publishers re-added.
#
# REDEPLOYING DataRegistry ALONE: the existing AppRegistry is repointed at it
# (`setDataRegistry`, admin-only). Every publisher must register again.
#
# NOTE ON REDEPLOYING DataRegistry: its `namespace_heads` mapping is every
# publisher's timeline head and does NOT survive a new deployment. Replay them
# with `seedNamespaceHead(app_id, publisher, subspace_id, root)` (admin-only, and
# fill-only — it refuses a slot that already holds a root) or every library
# published against the old address reads as empty.
#
# Runs interactively or non-interactively via TARGET environment variable:
#   TARGET=all|app-registry|data-registry|settlement
# ==============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
# Any variable below can be set in a .env next to this script (gitignored).
ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/.env"
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi

PRIVATE_KEY="${PRIVATE_KEY:?PRIVATE_KEY not set — export it or add it to .env}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
MAX_FEE="${MAX_FEE:-0.1}"

ADMIN_ADDR="${ADMIN_ADDR:-0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6}"
REGISTRATION_FEE="${REGISTRATION_FEE:-0}"
DEFAULT_APP_NAME="${DEFAULT_APP_NAME:-fangorn}"
# The default app's publisher terms: sha256 of the terms document, and where it is
# served. An app with a zero terms hash cannot be joined, so this must be real
# before any publisher can register for it.
# note: this hash is for testing only and has no real significance
DEFAULT_APP_TERMS_HASH="${DEFAULT_APP_TERMS_HASH:-0x9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08}"
DEFAULT_APP_TERMS_URI="${DEFAULT_APP_TERMS_URI:-https://fangorn.network/terms.html}"
DEFAULT_APP_JOIN_FEE="${DEFAULT_APP_JOIN_FEE:-0}"
SUBSCRIPTION_FEE="${SUBSCRIPTION_FEE:-0}"

# External Contract Dependencies
USDC_ADDR="${USDC_ADDR:-0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d}"
SEMAPHORE_ADDR="${SEMAPHORE_ADDR:-0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D}"

# The existing DataRegistry, required when deploying AppRegistry ALONE
DATA_REGISTRY_ADDR="${DATA_REGISTRY_ADDR:-}"
# An existing AppRegistry, when deploying DataRegistry ALONE
APP_REGISTRY_ADDR="${APP_REGISTRY_ADDR:-}"

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
    echo "  1) all                   (AppRegistry, DataRegistry, SettlementRegistry)" >&2
    echo "  2) DataRegistry only     (asks for an existing AppRegistry address)" >&2
    echo "  3) AppRegistry only      (asks for the existing DataRegistry address)" >&2
    echo "  4) SettlementRegistry only" >&2
    read -rp "Select [1/2/3/4]: " choice
    case "$choice" in
        1|all|both) TARGET="all" ;;
        2|data-registry|data_registry) TARGET="data-registry" ;;
        3|app-registry|app_registry) TARGET="app-registry" ;;
        4|settlement|settlement-registry|settlement_registry) TARGET="settlement" ;;
        *) echo "❌ Unrecognized choice: '$choice' (want 1, 2, 3, or 4)." >&2; exit 1 ;;
    esac
fi

echo "=========================================" >&2
echo " Deploying to Arbitrum Sepolia — target: $TARGET" >&2
echo "=========================================" >&2

APP_REGISTRY=""
DATA_REGISTRY=""
SETTLEMENT_REGISTRY=""
APP_ID=""

# ── 1. AppRegistry ────────────────────────────────────────────────────────────
# First, because DataRegistry takes its address in the constructor. It needs a
# DataRegistry too (to check that app owners and publishers are registered), so:
#   - alone: it is born pointing at the existing one, which must be given;
#   - with a fresh DataRegistry: it is born unwired and pointed at it in step 3.
if [ "$TARGET" = "app-registry" ]; then
    if ! is_address "$DATA_REGISTRY_ADDR"; then
        read -rp "Existing DataRegistry address (0x…): " DATA_REGISTRY_ADDR
    fi
    is_address "$DATA_REGISTRY_ADDR" \
        || { echo "❌ Invalid DataRegistry address: '${DATA_REGISTRY_ADDR:-<empty>}'." >&2; exit 1; }
    DATA_REGISTRY="$DATA_REGISTRY_ADDR"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "app-registry" ]; then
    log_step "Deploying AppRegistry"
    APP_REGISTRY=$(deploy_stylus "$SCRIPT_DIR/app_registry" \
        "$ADMIN_ADDR" "$USDC_ADDR" "$SUBSCRIPTION_FEE" "${DATA_REGISTRY:-$ZERO_ADDR}")
    echo "Verifying registry admin..." >&2
    cast_call "$APP_REGISTRY" "admin()(address)"
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
fi

# ── 3. Wire the pair ──────────────────────────────────────────────────────────
# Each registry consults the other, and whichever one already existed still points
# at its old partner. Both calls are admin-only. Until this is done the AppRegistry
# treats every wallet as unregistered (no app can be claimed), or the DataRegistry
# checks membership against the wrong AppRegistry.
if [ "$TARGET" = "all" ] || [ "$TARGET" = "data-registry" ]; then
    log_step "Pointing AppRegistry $APP_REGISTRY at DataRegistry $DATA_REGISTRY"
    cast_send "$APP_REGISTRY" "setDataRegistry(address)" "$DATA_REGISTRY"
fi
if [ "$TARGET" = "app-registry" ]; then
    log_step "Pointing DataRegistry $DATA_REGISTRY at AppRegistry $APP_REGISTRY"
    cast_send "$DATA_REGISTRY" "setAppRegistry(address)" "$APP_REGISTRY"
fi
if [ -n "$APP_REGISTRY" ] && [ -n "$DATA_REGISTRY" ]; then
    echo "AppRegistry.dataRegistry():" >&2
    cast_call "$APP_REGISTRY" "dataRegistry()(address)"
    echo "DataRegistry.appRegistry():" >&2
    cast_call "$DATA_REGISTRY" "appRegistry()(address)"
fi

# ── 4. Default app ────────────────────────────────────────────────────────────
# After the wiring: claiming an app requires the claimer to be a registered
# publisher in the DataRegistry, and pays the subscription fee.
if [ "$TARGET" = "all" ] || [ "$TARGET" = "app-registry" ]; then
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

    DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
    if [ "$(cast_call "$DATA_REGISTRY" "isRegistered(address)(bool)" "$DEPLOYER")" != "true" ]; then
        echo "Registering deployer $DEPLOYER as a publisher..." >&2
        REG_FEE=$(cast_call "$DATA_REGISTRY" "registrationFee()(uint256)" | awk '{print $1}')
        cast send "$DATA_REGISTRY" "register()" --value "$REG_FEE" \
            --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" > /dev/null
    fi

    # Claiming an app pays the subscription fee, pulled in USDC from the deployer.
    if [ "$SUBSCRIPTION_FEE" != "0" ]; then
        echo "Approving $SUBSCRIPTION_FEE USDC base units for the default app's subscription..." >&2
        cast_send "$USDC_ADDR" "approve(address,uint256)" "$APP_REGISTRY" "$SUBSCRIPTION_FEE"
    fi
    cast_send "$APP_REGISTRY" "registerApp(bytes32,bytes32,string,uint256)" \
        "$APP_ID" "$DEFAULT_APP_TERMS_HASH" "$DEFAULT_APP_TERMS_URI" "$DEFAULT_APP_JOIN_FEE"
    echo "Verifying app owner..." >&2
    cast_call "$APP_REGISTRY" "getAppOwner(bytes32)(address)" "$APP_ID"
fi

# ── 3. SettlementRegistry ─────────────────────────────────────────────────────
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
[ -n "$DATA_REGISTRY" ] && echo "DataRegistry:            $DATA_REGISTRY" >&2
[ -n "$APP_REGISTRY" ] && echo "AppRegistry:          $APP_REGISTRY" >&2
[ -n "$APP_ID" ] && echo "Default app \"$DEFAULT_APP_NAME\": $APP_ID" >&2
[ -n "$SETTLEMENT_REGISTRY" ]   && echo "SettlementRegistry:      $SETTLEMENT_REGISTRY" >&2
echo "=========================================" >&2