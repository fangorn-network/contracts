#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Deploys the Fangorn contracts to Arbitrum Sepolia.
#
# There are two implementations of the same three contracts, with the same ABI and
# the same initial arguments, so everything below the deploy step is shared:
#
#   IMPL=solidity (default)  solidity/src/*.sol, deployed with `forge create`
#   IMPL=stylus              stylus/<crate>,     deployed with `cargo stylus deploy`
#
# A Solidity contract is two deployments: the implementation, and an ERC-1967 proxy
# (UUPS) that holds the state. The proxy's address is the contract's address — the
# one printed here and used everywhere else. To change a contract that is already
# deployed, do not run this again: ./scripts/upgrade.sh swaps the implementation behind the
# proxy and keeps the address and the state. A Stylus contract is deployed directly
# and cannot be upgraded.
#
# Stylus needs the chain to accept new program activations. Check before using it:
#   cast call 0x0000000000000000000000000000000000000071 "activationGas()(uint64)" --rpc-url <rpc>
# A value in the millions is normal; 18446744073709551615 means activations are paused.
#
#   AppRegistry                   – app ids, per-app terms + join fees, invitation-only
#                                   publisher membership, and the paid storage
#                                   subscription: claiming an app pulls the USDC fee.
#                                   Cross-calls DataRegistry.isRegistered when an app
#                                   is claimed or a publisher added.
#   DataRegistry                  – publisher registration + state-root timeline.
#                                   Cross-calls AppRegistry.isRegisteredForApp in
#                                   commit_state_root.
#   SettlementRegistry            – ZK settlement registry with Semaphore & USDC auth.
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
# admin-only), keeping every namespace head. Apps and memberships do NOT carry over.
#
# REDEPLOYING DataRegistry ALONE: the existing AppRegistry is repointed at it
# (`setDataRegistry`, admin-only). Registrations and namespace heads do NOT carry
# over, so every library published against the old address reads as empty.
#
# AFTER ANY OF THESE: ./scripts/migrate.sh copies the old registries' apps, memberships,
# publishers and namespace heads into the new ones (Solidity targets only).
#
# Run from anywhere, e.g. ./scripts/deploy.sh from the repo root. Interactive, or
# non-interactive via the TARGET environment variable:
#   TARGET=all|app-registry|data-registry|settlement
#   IMPL=solidity|stylus
# ==============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
# Any variable below can be set in a .env at the repo root (gitignored).
ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/../.env"
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi

PRIVATE_KEY="${PRIVATE_KEY:?PRIVATE_KEY not set — export it or add it to .env}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
MAX_FEE="${MAX_FEE:-0.1}"   # Stylus only: max fee per gas, in gwei
IMPL="${IMPL:-solidity}"
case "$IMPL" in
    solidity|stylus) ;;
    *) echo "❌ IMPL must be 'solidity' or 'stylus', got '$IMPL'." >&2; exit 1 ;;
esac

# No default: the admin can change fees, take apps down and upgrade the contracts, so
# it is never chosen for the caller. Zero is refused too: nobody could upgrade.
ADMIN_ADDR="${ADMIN_ADDR:?ADMIN_ADDR not set — export it or add it to .env}"
if [[ ! "$ADMIN_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$ADMIN_ADDR" =~ ^0x0{40}$ ]]; then
    echo "❌ ADMIN_ADDR must be a non-zero address, got '$ADMIN_ADDR'." >&2
    exit 1
fi
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
# The proxy every Solidity contract sits behind (path is relative to solidity/)
PROXY_CONTRACT="lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repo root: solidity/, stylus/ and layout/ live there, one level up.
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
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

# Print the last deploy tool's log, and the address it reported after `marker`.
deployed_address() {
    cat "$LOG_FILE" >&2
    local address
    address=$(grep -i "$1" "$LOG_FILE" \
        | grep -oE '0x[a-fA-F0-9]{40}' | head -n1 | tr -d '[:space:]')
    [ -n "$address" ] || { echo "❌ No address in logs." >&2; exit 1; }
    echo "$address"
}

# Deploy one contract with the chosen implementation. The first argument is the
# crate name (app_registry | data_registry | settlement_registry); the rest are its
# initial arguments, which are the same for both implementations: a Stylus
# constructor takes them, and so does a Solidity `initialize`.
deploy_contract() {
    local name="$1"; shift
    # This runs inside $(…), where bash switches `set -e` off: every step that can
    # fail says `|| exit 1` itself.
    local address
    if [ "$IMPL" = "stylus" ]; then
        echo "Deploying Stylus contract stylus/$name..." >&2
        (cd "$ROOT_DIR/stylus/$name" && cargo stylus deploy \
            --private-key "$PRIVATE_KEY" --endpoint "$RPC_ENDPOINT" \
            --max-fee-per-gas-gwei "$MAX_FEE" \
            --constructor-args "$@") > "$LOG_FILE" 2>&1 || { cat "$LOG_FILE" >&2; exit 1; }
        address=$(deployed_address "deployed code at address:") || exit 1
    else
        local contract init
        case "$name" in
            app_registry)        contract="AppRegistry";        init="initialize(address,address,uint256,address)" ;;
            data_registry)       contract="DataRegistry";       init="initialize(address,uint256,address)" ;;
            settlement_registry) contract="SettlementRegistry"; init="initialize(address,address,address)" ;;
            *) echo "❌ Unknown contract '$name'." >&2; exit 1 ;;
        esac
        echo "Deploying Solidity implementation solidity/src/$contract.sol..." >&2
        (cd "$ROOT_DIR/solidity" && forge create "src/$contract.sol:$contract" \
            --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" --broadcast) \
            > "$LOG_FILE" 2>&1 || { cat "$LOG_FILE" >&2; exit 1; }
        local implementation
        implementation=$(deployed_address "Deployed to:") || exit 1

        # The proxy's constructor runs `initialize` with the arguments, so the contract
        # is never live and uninitialized. --constructor-args takes everything after
        # it, so it goes last.
        echo "Deploying its proxy (implementation $implementation)..." >&2
        (cd "$ROOT_DIR/solidity" && forge create "$PROXY_CONTRACT" \
            --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" --broadcast \
            --constructor-args "$implementation" "$(cast calldata "$init" "$@")") \
            > "$LOG_FILE" 2>&1 || { cat "$LOG_FILE" >&2; exit 1; }
        address=$(deployed_address "Deployed to:") || exit 1

        # What upgrade.sh will compare the next implementation against.
        "$SCRIPT_DIR/layout.sh" write "$contract" "$(cast chain-id --rpc-url "$RPC_ENDPOINT")" || exit 1
    fi
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
echo " Deploying ($IMPL) to $RPC_ENDPOINT — target: $TARGET" >&2
echo "=========================================" >&2

APP_REGISTRY=""
DATA_REGISTRY=""
SETTLEMENT_REGISTRY=""
APP_ID=""

# ── 1. AppRegistry ────────────────────────────────────────────────────────────
# First, because DataRegistry takes its address when it is created. It needs a
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
    APP_REGISTRY=$(deploy_contract app_registry \
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
    DATA_REGISTRY=$(deploy_contract data_registry \
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
    # to verify at deploy time. The admin (takedown and upgrade authority, may be
    # the zero address for a registry nobody can administer) is the last argument.
    SETTLEMENT_REGISTRY=$(deploy_contract settlement_registry \
        "$USDC_ADDR" "$SEMAPHORE_ADDR" "$ADMIN_ADDR")
    echo "Verifying settlement registry admin..." >&2
    cast_call "$SETTLEMENT_REGISTRY" "getAdmin()(address)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n=========================================" >&2
echo " 🎉 Deployment complete ($IMPL)" >&2
echo "=========================================" >&2
[ -n "$DATA_REGISTRY" ] && echo "DataRegistry:            $DATA_REGISTRY" >&2
[ -n "$APP_REGISTRY" ] && echo "AppRegistry:          $APP_REGISTRY" >&2
[ -n "$APP_ID" ] && echo "Default app \"$DEFAULT_APP_NAME\": $APP_ID" >&2
[ -n "$SETTLEMENT_REGISTRY" ]   && echo "SettlementRegistry:      $SETTLEMENT_REGISTRY" >&2
echo "=========================================" >&2