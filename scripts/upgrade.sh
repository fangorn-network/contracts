#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Upgrades one proxied Solidity contract in place: deploys a new implementation and
# points the existing proxy at it. The address and every byte of state stay, so there
# is nothing to migrate and nothing to repoint.
#
#   CONTRACT=AppRegistry PROXY=0x… ./scripts/upgrade.sh
#
#   CONTRACT   AppRegistry | DataRegistry | SettlementRegistry
#   PROXY      the contract's address (what deploy.sh printed, what the SDK uses)
#   INIT_DATA  optional calldata to run on the new implementation in the same
#              transaction, for an upgrade that has to set up new state
#              (a `reinitializer` function). Default: none.
#
# Run with the admin key (and, like deploy.sh, an optional .env at the repo root). Only the contract's admin can upgrade it.
#
# The new implementation must keep the storage layout: layout.sh refuses the upgrade
# if a slot that is live was moved, retyped or removed. Appending is fine.
#
# Solidity only. The Stylus contracts are deployed directly and cannot be upgraded.
# ==============================================================================

ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/../.env"
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi

PRIVATE_KEY="${PRIVATE_KEY:?PRIVATE_KEY not set — export it or add it to .env}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
CONTRACT="${CONTRACT:?CONTRACT not set — AppRegistry, DataRegistry or SettlementRegistry}"
PROXY="${PROXY:?PROXY not set — the address of the deployed contract}"
INIT_DATA="${INIT_DATA:-0x}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repo root: solidity/, stylus/ and layout/ live there, one level up.
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ZERO_ADDR="0x0000000000000000000000000000000000000000"

# PROBE is a view only that contract has: it tells the three apart on-chain.
case "$CONTRACT" in
    AppRegistry)        ADMIN_GETTER="admin()(address)";    PROBE="subscriptionFee()(uint256)" ;;
    DataRegistry)       ADMIN_GETTER="admin()(address)";    PROBE="publisherCount()(uint64)" ;;
    SettlementRegistry) ADMIN_GETTER="getAdmin()(address)"; PROBE="getSemaphore()(address)" ;;
    *) echo "❌ CONTRACT must be AppRegistry, DataRegistry or SettlementRegistry, got '$CONTRACT'." >&2; exit 1 ;;
esac
[[ "$PROXY" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "❌ Invalid PROXY address: '$PROXY'." >&2; exit 1; }

lower() { tr '[:upper:]' '[:lower:]' <<< "$1"; }
implementation_of() { cast implementation "$PROXY" --rpc-url "$RPC_ENDPOINT"; }

# ── Preflight: fail before anything is deployed ───────────────────────────────
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_ENDPOINT")
OLD_IMPLEMENTATION=$(implementation_of)
if [ "$(lower "$OLD_IMPLEMENTATION")" = "$ZERO_ADDR" ]; then
    echo "❌ $PROXY is not an ERC-1967 proxy on chain $CHAIN_ID (no implementation set)." >&2
    exit 1
fi

# The proxy must really be a $CONTRACT. Each contract keeps its admin in a different
# storage slot, so one contract's code behind another's proxy reads no admin at all:
# nobody could upgrade it back.
if ! cast call "$PROXY" "$PROBE" --rpc-url "$RPC_ENDPOINT" > /dev/null 2>&1; then
    echo "❌ $PROXY does not answer ${PROBE%%(*}() — it is not a $CONTRACT." >&2
    echo "   Upgrading it with $CONTRACT code would break it for good. Check CONTRACT and" >&2
    echo "   PROXY (a value in .env overrides the command line)." >&2
    exit 1
fi

SIGNER=$(cast wallet address --private-key "$PRIVATE_KEY")
ADMIN=$(cast call "$PROXY" "$ADMIN_GETTER" --rpc-url "$RPC_ENDPOINT")
if [ "$(lower "$SIGNER")" != "$(lower "$ADMIN")" ]; then
    echo "❌ $SIGNER is not the admin of $PROXY ($ADMIN) — the upgrade would revert." >&2
    exit 1
fi

"$SCRIPT_DIR/layout.sh" check "$CONTRACT" "$CHAIN_ID"

echo "=========================================" >&2
echo " Upgrading $CONTRACT at $PROXY (chain $CHAIN_ID)" >&2
echo " Current implementation: $OLD_IMPLEMENTATION" >&2
echo "=========================================" >&2

# ── Deploy the new implementation ─────────────────────────────────────────────
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT
(cd "$ROOT_DIR/solidity" && forge create "src/$CONTRACT.sol:$CONTRACT" \
    --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" --broadcast) > "$LOG_FILE" 2>&1 \
    || { cat "$LOG_FILE" >&2; exit 1; }
cat "$LOG_FILE" >&2
NEW_IMPLEMENTATION=$(grep -i "Deployed to:" "$LOG_FILE" | grep -oE '0x[a-fA-F0-9]{40}' | head -n1)
[ -n "$NEW_IMPLEMENTATION" ] || { echo "❌ No address in logs." >&2; exit 1; }

# ── Point the proxy at it ─────────────────────────────────────────────────────
# The old implementation checks that the new one is a UUPS implementation too, so a
# contract that could never be upgraded again is refused here.
cast send "$PROXY" "upgradeToAndCall(address,bytes)" "$NEW_IMPLEMENTATION" "$INIT_DATA" \
    --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" > /dev/null

LIVE=$(implementation_of)
if [ "$(lower "$LIVE")" != "$(lower "$NEW_IMPLEMENTATION")" ]; then
    echo "❌ $PROXY still points at $LIVE, not $NEW_IMPLEMENTATION." >&2
    exit 1
fi
"$SCRIPT_DIR/layout.sh" write "$CONTRACT" "$CHAIN_ID"

echo "=========================================" >&2
echo " 🎉 $CONTRACT upgraded" >&2
echo " Address (unchanged):  $PROXY" >&2
echo " Implementation:       $NEW_IMPLEMENTATION" >&2
echo "=========================================" >&2
