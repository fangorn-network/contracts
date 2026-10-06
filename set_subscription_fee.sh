#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Updates the subscription fee on a deployed AppRegistry (admin-only): what claiming
# or renewing an app costs.
#
# Usage:
#   ./set_subscription_fee.sh <amount-in-USDC>
#   APP_REGISTRY_ADDR=0x… ./set_subscription_fee.sh 5        # $5 per period
#   ./set_subscription_fee.sh                                # prompts for both
#
# The amount is given in USDC (decimals allowed, e.g. 5 or 2.5) and converted to
# the contract's 6-decimal base units. Requires the admin PRIVATE_KEY.
# ==============================================================================

# ── Configuration (env-overridable, same defaults as deploy.sh) ───────────────
PRIVATE_KEY="${PRIVATE_KEY:-0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb}"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
# The deployed AppRegistry. Prompted if empty.
APP_REGISTRY_ADDR="${APP_REGISTRY_ADDR:-}"

command -v cast >/dev/null || { echo "❌ 'cast' (foundry) not found on PATH." >&2; exit 1; }

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

# Decimal USDC → 6-decimal base units, exact (string math, no float rounding).
usdc_to_base() {
    local amount="$1"
    [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    local int="${amount%%.*}" frac=""
    [[ "$amount" == *.* ]] && frac="${amount#*.}"
    frac="${frac}000000"          # pad, then keep exactly 6 fractional digits
    frac="${frac:0:6}"
    echo "$((10#${int}${frac}))"
}

# ── Resolve the contract address ──────────────────────────────────────────────
if ! is_address "$APP_REGISTRY_ADDR"; then
    read -rp "AppRegistry address (0x…): " APP_REGISTRY_ADDR
fi
is_address "$APP_REGISTRY_ADDR" \
    || { echo "❌ Invalid AppRegistry address: '${APP_REGISTRY_ADDR:-<empty>}'." >&2; exit 1; }

# ── Resolve the new amount (USDC) ─────────────────────────────────────────────
AMOUNT="${1:-}"
if [ -z "$AMOUNT" ]; then
    read -rp "New subscription fee in USDC (e.g. 5 or 2.5): " AMOUNT
fi
BASE=$(usdc_to_base "$AMOUNT") \
    || { echo "❌ Invalid amount: '$AMOUNT' (want a number like 5 or 2.5)." >&2; exit 1; }

# ── Admin sanity check (setSubscriptionFee is only_admin) ─────────────────────
SIGNER=$(cast wallet address --private-key "$PRIVATE_KEY")
ADMIN=$(cast call "$APP_REGISTRY_ADDR" "admin()(address)" --rpc-url "$RPC_ENDPOINT" | awk '{print $1}')
if [ "${SIGNER,,}" != "${ADMIN,,}" ]; then
    echo "⚠️  Signer $SIGNER is not the contract admin ($ADMIN) — the tx will revert." >&2
    read -rp "Continue anyway? [y/N] " ok
    [[ "$ok" =~ ^[Yy]$ ]] || exit 1
fi

CURRENT=$(cast call "$APP_REGISTRY_ADDR" "subscriptionFee()(uint256)" --rpc-url "$RPC_ENDPOINT" | awk '{print $1}')
echo "Contract:  $APP_REGISTRY_ADDR" >&2
echo "Current:   $CURRENT base units" >&2
echo "New:       $AMOUNT USDC = $BASE base units" >&2

echo "Sending setSubscriptionFee($BASE)…" >&2
cast send "$APP_REGISTRY_ADDR" "setSubscriptionFee(uint256)" "$BASE" \
    --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" > /dev/null

# ── Verify the on-chain value took ────────────────────────────────────────────
UPDATED=$(cast call "$APP_REGISTRY_ADDR" "subscriptionFee()(uint256)" --rpc-url "$RPC_ENDPOINT" | awk '{print $1}')
if [ "$UPDATED" = "$BASE" ]; then
    echo "✅ Subscription fee is now $BASE base units ($AMOUNT USDC)." >&2
else
    echo "❌ Update did not take — fee reads $UPDATED, expected $BASE." >&2
    exit 1
fi
