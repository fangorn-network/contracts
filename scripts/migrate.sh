#!/usr/bin/env bash

set -euo pipefail
# A failed read inside $(…) must stop the script, not come back as an empty value.
shopt -s inherit_errexit

# ==============================================================================
# Copies the state of an old AppRegistry and DataRegistry into freshly deployed
# Solidity ones. Run it after ./scripts/deploy.sh, with the admin key.
#
#   DataRegistry   every registered publisher (a suspended one stays suspended) and
#                  every namespace head
#   AppRegistry    every app, for its original owner, with its terms, join fee, agent
#                  card and suspension flag; and every membership, with the terms
#                  hash that publisher accepted
#
# TESTNET ONLY: a migrated app pays no subscription fee and is stamped as paid at the
# moment it is seeded, not when it last paid on the old contract.
#
# The old contracts' logs only say WHICH apps, publishers and namespaces exist. Every
# value is then read from the old contracts' views, so what is copied is their state
# now, not their history.
#
# Safe to re-run: anything the new contracts already hold is left alone, and every
# item is compared against the old contracts whether it was copied this run or not.
# Exits non-zero if anything differs.
#
# Usage:
#   APP_REGISTRY_ADDR=0x… DATA_REGISTRY_ADDR=0x… ./scripts/migrate.sh
#
# When only the AppRegistry was redeployed (TARGET=app-registry), pass the DataRegistry
# it sits in front of: DATA_REGISTRY_ADDR equal to OLD_DATA_REGISTRY skips that half.
#
# Not migrated: the SettlementRegistry.
#
# Leaving a wallet behind (its key is lost or compromised):
#   RETIRED_WALLET=0x… APP_REGISTRY_ADDR=0x… DATA_REGISTRY_ADDR=0x… ./scripts/migrate.sh
# Nothing that wallet owns is carried over: not its publisher registration, its
# namespace heads, the apps it owns, or its memberships. An app it owned that already
# exists on the new contract — the default app, claimed afresh by deploy.sh for the new
# admin — keeps its new owner and is compared in everything else.
# ==============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
# Any variable below can be set in a .env at the repo root (gitignored).
ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/../.env"
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi

# The admin of the NEW contracts: every write below is admin-only.
PRIVATE_KEY="${PRIVATE_KEY:?PRIVATE_KEY not set — export it or add it to .env}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
# Where the old contracts live. Differs from RPC_ENDPOINT only when rehearsing
# against a local chain.
OLD_RPC_ENDPOINT="${OLD_RPC_ENDPOINT:-$RPC_ENDPOINT}"

# The new contracts
APP_REGISTRY_ADDR="${APP_REGISTRY_ADDR:-}"
DATA_REGISTRY_ADDR="${DATA_REGISTRY_ADDR:-}"
# The contracts being migrated away from (the Stylus deployment)
OLD_APP_REGISTRY="${OLD_APP_REGISTRY:-0x11d228c4774af3d9cae3b4b6874a12576a1a83ec}"
OLD_DATA_REGISTRY="${OLD_DATA_REGISTRY:-0x775026e905d7b58b34d16bcbd385fa630ee36c26}"

# Where to start reading the old contracts' logs. Theirs begin at block 311637349.
FROM_BLOCK="${FROM_BLOCK:-311600000}"
# The public Arbitrum RPC refuses an eth_getLogs spanning more than this many blocks.
LOG_WINDOW="${LOG_WINDOW:-10000000}"
# A wallet to leave behind (see the top of this file). Optional.
RETIRED_WALLET="${RETIRED_WALLET:-}"

STATUS_UNREGISTERED=0
STATUS_SUSPENDED=2
ZERO_ADDR="0x0000000000000000000000000000000000000000"
ZERO_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"

command -v cast >/dev/null || { echo "❌ 'cast' (foundry) not found on PATH." >&2; exit 1; }
command -v jq >/dev/null || { echo "❌ 'jq' not found on PATH." >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
log_step() {
    echo -e "\n==================================================" >&2
    echo -e "🚀 $1" >&2
    echo -e "==================================================" >&2
}

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
same_address() { [ "${1,,}" = "${2,,}" ]; }

# Read one value. cast prints big numbers as `1000 [1e3]`, so keep the first word.
call_at() {
    local rpc="$1" contract="$2" signature="$3"; shift 3
    cast call "$contract" "$signature" "$@" --rpc-url "$rpc" | awk '{print $1}'
}
old() { call_at "$OLD_RPC_ENDPOINT" "$@"; }
new() { call_at "$RPC_ENDPOINT" "$@"; }

# Read one string, unquoted and unescaped.
old_string() {
    local contract="$1" signature="$2"; shift 2
    cast call "$contract" "$signature" "$@" --rpc-url "$OLD_RPC_ENDPOINT" --json | jq -r '.[0]'
}
new_string() {
    local contract="$1" signature="$2"; shift 2
    cast call "$contract" "$signature" "$@" --rpc-url "$RPC_ENDPOINT" --json | jq -r '.[0]'
}

send() {
    local contract="$1" signature="$2"; shift 2
    cast send "$contract" "$signature" "$@" \
        --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" > /dev/null
}

# Every log an old contract ever emitted, one JSON object per line.
fetch_logs() {
    local address="$1" from="$FROM_BLOCK" head to
    head=$(cast block-number --rpc-url "$OLD_RPC_ENDPOINT")
    while [ "$from" -le "$head" ]; do
        to=$((from + LOG_WINDOW - 1))
        if [ "$to" -gt "$head" ]; then to="$head"; fi
        cast logs --from-block "$from" --to-block "$to" --address "$address" \
            --rpc-url "$OLD_RPC_ENDPOINT" --json | jq -c '.[]'
        from=$((to + 1))
    done
}

# Sets KEYS to the distinct keys named by a set of events:
# `keys <logs> <jq row> <event>…`. An indexed address is a 32-byte topic; its last
# 20 bytes are the address.
keys() {
    local logs="$1" row="$2" topics found; shift 2
    topics=$(for event in "$@"; do cast sig-event "$event"; done | jq -R . | jq -cs .)
    found=$(jq -r --argjson topics "$topics" \
        "select(.topics[0] as \$t | \$topics | index(\$t)) | $row" <<< "$logs" | sort -u)
    KEYS=()
    if [ -n "$found" ]; then mapfile -t KEYS <<< "$found"; fi
}

SEEDED=0
SKIPPED=0
MISMATCHED=0
LEFT_BEHIND=0

retired() { [ -n "$RETIRED_WALLET" ] && same_address "$1" "$RETIRED_WALLET"; }
leave_behind() {
    echo "left behind: $1" >&2
    LEFT_BEHIND=$((LEFT_BEHIND + 1))
}

# Compare one migrated value against the old contract's.
check() {
    local what="$1" was="$2" is="$3"
    if [ "$was" != "$is" ]; then
        echo "❌ $what: old contract has '$was', new one has '$is'" >&2
        MISMATCHED=$((MISMATCHED + 1))
    fi
}

# ── Preflight ─────────────────────────────────────────────────────────────────
for name in APP_REGISTRY_ADDR DATA_REGISTRY_ADDR OLD_APP_REGISTRY OLD_DATA_REGISTRY; do
    is_address "${!name}" || { echo "❌ $name is not an address: '${!name:-<empty>}'." >&2; exit 1; }
done
if same_address "$APP_REGISTRY_ADDR" "$OLD_APP_REGISTRY"; then
    echo "❌ APP_REGISTRY_ADDR is the old AppRegistry — nothing to migrate." >&2; exit 1
fi
MIGRATE_DATA=true
if same_address "$DATA_REGISTRY_ADDR" "$OLD_DATA_REGISTRY"; then MIGRATE_DATA=false; fi

SIGNER=$(cast wallet address --private-key "$PRIVATE_KEY")
if [ -n "$RETIRED_WALLET" ]; then
    is_address "$RETIRED_WALLET" \
        || { echo "❌ RETIRED_WALLET is not an address: '$RETIRED_WALLET'." >&2; exit 1; }
    if same_address "$RETIRED_WALLET" "$SIGNER"; then
        echo "❌ RETIRED_WALLET is the signer. Sign with the wallet that replaces it." >&2; exit 1
    fi
    if ! $MIGRATE_DATA; then
        echo "❌ RETIRED_WALLET needs a new DataRegistry: the old one would keep that" >&2
        echo "   wallet's registration and heads, and DATA_REGISTRY_ADDR is the old one." >&2
        exit 1
    fi
fi
ADMIN=$(new "$APP_REGISTRY_ADDR" "admin()(address)")
same_address "$SIGNER" "$ADMIN" \
    || { echo "❌ Signer $SIGNER is not the new AppRegistry's admin ($ADMIN)." >&2; exit 1; }
if $MIGRATE_DATA; then
    ADMIN=$(new "$DATA_REGISTRY_ADDR" "admin()(address)")
    same_address "$SIGNER" "$ADMIN" \
        || { echo "❌ Signer $SIGNER is not the new DataRegistry's admin ($ADMIN)." >&2; exit 1; }
fi

echo "=========================================" >&2
echo " Migrating" >&2
echo "   AppRegistry   $OLD_APP_REGISTRY -> $APP_REGISTRY_ADDR" >&2
if $MIGRATE_DATA; then
    echo "   DataRegistry  $OLD_DATA_REGISTRY -> $DATA_REGISTRY_ADDR" >&2
else
    echo "   DataRegistry  $DATA_REGISTRY_ADDR (kept, not migrated)" >&2
fi
if [ -n "$RETIRED_WALLET" ]; then
    echo "   Leaving behind everything owned by $RETIRED_WALLET" >&2
fi
echo "=========================================" >&2

# ── 1. DataRegistry: publishers ───────────────────────────────────────────────
if $MIGRATE_DATA; then
    log_step "Reading the old DataRegistry's logs"
    DATA_LOGS=$(fetch_logs "$OLD_DATA_REGISTRY")

    keys "$DATA_LOGS" '"0x" + .topics[1][26:]' "PublisherRegistered(address,bytes32)"
    log_step "Publishers: ${#KEYS[@]}"
    for publisher in "${KEYS[@]}"; do
        if retired "$publisher"; then leave_behind "publisher $publisher"; continue; fi
        status=$(old "$OLD_DATA_REGISTRY" "getPublisherStatus(address)(uint8)" "$publisher")
        if [ "$(new "$DATA_REGISTRY_ADDR" "getPublisherStatus(address)(uint8)" "$publisher")" != "$STATUS_UNREGISTERED" ]; then
            SKIPPED=$((SKIPPED + 1))
        else
            echo "publisher $publisher (status $status)" >&2
            send "$DATA_REGISTRY_ADDR" "seedPublisher(address)" "$publisher"
            # A banned publisher stays banned.
            if [ "$status" = "$STATUS_SUSPENDED" ]; then
                send "$DATA_REGISTRY_ADDR" "suspendPublisher(address)" "$publisher"
            fi
            SEEDED=$((SEEDED + 1))
        fi
        check "publisher $publisher status" "$status" \
            "$(new "$DATA_REGISTRY_ADDR" "getPublisherStatus(address)(uint8)" "$publisher")"
    done

    # ── 2. DataRegistry: namespace heads ──────────────────────────────────────
    # app_id and publisher are indexed; subspace_id is the first word of the data.
    keys "$DATA_LOGS" '"\(.topics[2]) 0x\(.topics[3][26:]) \(.data[0:66])"' \
        "StateCommitted(bytes32,bytes32,address,bytes32,bytes32,bytes32)"
    log_step "Namespace heads: ${#KEYS[@]}"
    for namespace in "${KEYS[@]}"; do
        read -r app_id publisher subspace_id <<< "$namespace"
        if retired "$publisher"; then
            leave_behind "head $app_id / $publisher / $subspace_id"; continue
        fi
        head_sig="getNamespaceHead(bytes32,address,bytes32)(bytes32)"
        root=$(old "$OLD_DATA_REGISTRY" "$head_sig" "$app_id" "$publisher" "$subspace_id")
        if [ "$(new "$DATA_REGISTRY_ADDR" "$head_sig" "$app_id" "$publisher" "$subspace_id")" != "$ZERO_HASH" ] \
            || [ "$root" = "$ZERO_HASH" ]; then
            SKIPPED=$((SKIPPED + 1))
        else
            echo "head $app_id / $publisher / $subspace_id" >&2
            send "$DATA_REGISTRY_ADDR" "seedNamespaceHead(bytes32,address,bytes32,bytes32)" \
                "$app_id" "$publisher" "$subspace_id" "$root"
            SEEDED=$((SEEDED + 1))
        fi
        check "head $app_id / $publisher / $subspace_id" "$root" \
            "$(new "$DATA_REGISTRY_ADDR" "$head_sig" "$app_id" "$publisher" "$subspace_id")"
    done
fi

# ── 3. AppRegistry: apps ──────────────────────────────────────────────────────
log_step "Reading the old AppRegistry's logs"
APP_LOGS=$(fetch_logs "$OLD_APP_REGISTRY")

keys "$APP_LOGS" '.topics[1]' "AppRegistered(bytes32,address)"
log_step "Apps: ${#KEYS[@]}"
for app_id in "${KEYS[@]}"; do
    owner=$(old "$OLD_APP_REGISTRY" "getAppOwner(bytes32)(address)" "$app_id")
    terms=$(old "$OLD_APP_REGISTRY" "appTerms(bytes32)(bytes32)" "$app_id")
    terms_uri=$(old_string "$OLD_APP_REGISTRY" "appTermsUri(bytes32)(string)" "$app_id")
    fee=$(old "$OLD_APP_REGISTRY" "appFee(bytes32)(uint256)" "$app_id")
    agent_uri=$(old_string "$OLD_APP_REGISTRY" "appAgentUri(bytes32)(string)" "$app_id")
    suspended=$(old "$OLD_APP_REGISTRY" "isAppSuspended(bytes32)(bool)" "$app_id")

    if retired "$owner"; then
        owner=$(new "$APP_REGISTRY_ADDR" "getAppOwner(bytes32)(address)" "$app_id")
        if [ "$owner" = "$ZERO_ADDR" ]; then leave_behind "app $app_id"; continue; fi
        # Claimed afresh on the new contract: whoever holds it now stays its owner —
        # unless that is the retired wallet again.
        if retired "$owner"; then
            echo "❌ app $app_id belongs to the retired wallet on the new contract" >&2
            MISMATCHED=$((MISMATCHED + 1))
        fi
    fi

    if [ "$(new "$APP_REGISTRY_ADDR" "getAppOwner(bytes32)(address)" "$app_id")" != "$ZERO_ADDR" ]; then
        SKIPPED=$((SKIPPED + 1))
    else
        echo "app $app_id (owner $owner)" >&2
        send "$APP_REGISTRY_ADDR" "seedApp(bytes32,address,bytes32,string,uint256,string)" \
            "$app_id" "$owner" "$terms" "$terms_uri" "$fee" "$agent_uri"
        # A taken-down app stays down.
        if [ "$suspended" = "true" ]; then
            send "$APP_REGISTRY_ADDR" "suspendApp(bytes32)" "$app_id"
        fi
        SEEDED=$((SEEDED + 1))
    fi

    check "app $app_id owner" "$owner" \
        "$(new "$APP_REGISTRY_ADDR" "getAppOwner(bytes32)(address)" "$app_id")"
    check "app $app_id terms" "$terms" \
        "$(new "$APP_REGISTRY_ADDR" "appTerms(bytes32)(bytes32)" "$app_id")"
    check "app $app_id terms uri" "$terms_uri" \
        "$(new_string "$APP_REGISTRY_ADDR" "appTermsUri(bytes32)(string)" "$app_id")"
    check "app $app_id join fee" "$fee" \
        "$(new "$APP_REGISTRY_ADDR" "appFee(bytes32)(uint256)" "$app_id")"
    check "app $app_id agent uri" "$agent_uri" \
        "$(new_string "$APP_REGISTRY_ADDR" "appAgentUri(bytes32)(string)" "$app_id")"
    check "app $app_id suspended" "$suspended" \
        "$(new "$APP_REGISTRY_ADDR" "isAppSuspended(bytes32)(bool)" "$app_id")"
    if [ "$(new "$APP_REGISTRY_ADDR" "subscribedAt(bytes32)(uint64)" "$app_id")" = "0" ]; then
        echo "❌ app $app_id has no subscription stamp on the new contract" >&2
        MISMATCHED=$((MISMATCHED + 1))
    fi
done

# ── 4. AppRegistry: memberships ───────────────────────────────────────────────
# After the apps: a membership cannot be seeded into an app that does not exist. An
# app's owner is already a member of it (seedApp does that), so those are skipped.
keys "$APP_LOGS" '"\(.topics[1]) 0x\(.topics[2][26:])"' \
    "PublisherJoined(bytes32,address,bytes32,uint256)" \
    "PublisherInvited(bytes32,address)" \
    "PublisherSuspendedForApp(bytes32,address)" \
    "PublisherReinstatedForApp(bytes32,address)"
log_step "Memberships: ${#KEYS[@]}"
for member in "${KEYS[@]}"; do
    read -r app_id publisher <<< "$member"
    if retired "$publisher"; then leave_behind "member $publisher of $app_id"; continue; fi
    # A member of an app that was itself left behind has nothing to be seeded into.
    if [ "$(new "$APP_REGISTRY_ADDR" "getAppOwner(bytes32)(address)" "$app_id")" = "$ZERO_ADDR" ]; then
        leave_behind "member $publisher of $app_id (the app was left behind)"; continue
    fi
    status=$(old "$OLD_APP_REGISTRY" "statusForApp(bytes32,address)(uint8)" "$app_id" "$publisher")
    accepted=$(old "$OLD_APP_REGISTRY" "acceptedTerms(bytes32,address)(bytes32)" "$app_id" "$publisher")
    if [ "$(new "$APP_REGISTRY_ADDR" "statusForApp(bytes32,address)(uint8)" "$app_id" "$publisher")" != "$STATUS_UNREGISTERED" ] \
        || [ "$status" = "$STATUS_UNREGISTERED" ]; then
        SKIPPED=$((SKIPPED + 1))
    else
        echo "member $publisher of $app_id (status $status)" >&2
        send "$APP_REGISTRY_ADDR" "seedPublisherForApp(bytes32,address,uint8,bytes32)" \
            "$app_id" "$publisher" "$status" "$accepted"
        SEEDED=$((SEEDED + 1))
    fi
    check "member $publisher of $app_id status" "$status" \
        "$(new "$APP_REGISTRY_ADDR" "statusForApp(bytes32,address)(uint8)" "$app_id" "$publisher")"
    check "member $publisher of $app_id accepted terms" "$accepted" \
        "$(new "$APP_REGISTRY_ADDR" "acceptedTerms(bytes32,address)(bytes32)" "$app_id" "$publisher")"
    check "member $publisher of $app_id registered" \
        "$(old "$OLD_APP_REGISTRY" "isRegisteredForApp(bytes32,address)(bool)" "$app_id" "$publisher")" \
        "$(new "$APP_REGISTRY_ADDR" "isRegisteredForApp(bytes32,address)(bool)" "$app_id" "$publisher")"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n=========================================" >&2
echo " Seeded:      $SEEDED" >&2
echo " Already set: $SKIPPED" >&2
echo " Mismatched:  $MISMATCHED" >&2
if [ -n "$RETIRED_WALLET" ]; then echo " Left behind: $LEFT_BEHIND" >&2; fi
echo "=========================================" >&2
if [ "$MISMATCHED" -ne 0 ]; then
    echo "❌ The new contracts do not match the old ones. See above." >&2
    exit 1
fi
if [ "$LEFT_BEHIND" -ne 0 ]; then
    echo "✅ The new contracts match the old ones, apart from what was left behind." >&2
else
    echo "✅ The new contracts match the old ones." >&2
fi
