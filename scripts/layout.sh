#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Guards an upgrade of a proxied Solidity contract against a storage-layout change.
#
# The proxy keeps its storage across upgrades, so a new implementation has to read
# every existing slot the way the old one wrote it. Appending is safe: a new state
# variable after the last one, or a new field at the end of a struct that is only
# ever a mapping value. Moving, retyping or removing anything is not — the new code
# would read old data as something else, and nothing would revert.
#
#   ./scripts/layout.sh write <Contract> <chain-id>   record the layout that was just deployed
#   ./scripts/layout.sh check <Contract> <chain-id>   fail unless every recorded line still holds
#
# Snapshots are layout/<chain-id>/<Contract>.txt at the repo root, one line per
# state variable or struct field: "name slot offset type". deploy.sh and upgrade.sh
# call this; commit the files they write, since they describe what is live.
#
# A rename fails the check too. It is harmless to storage: confirm that is all it is,
# then `write` a new snapshot by hand.
# ==============================================================================

# One collation for writing and checking, whatever the caller's locale.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repo root: solidity/ and layout/ live there, one level up.
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MODE="${1:-}"; CONTRACT="${2:-}"; CHAIN_ID="${3:-}"
if [[ ! "$MODE" =~ ^(write|check)$ ]] || [ -z "$CONTRACT" ] || [ -z "$CHAIN_ID" ]; then
    echo "usage: $0 write|check <Contract> <chain-id>" >&2
    exit 1
fi
SNAPSHOT="$ROOT_DIR/layout/$CHAIN_ID/$CONTRACT.txt"

# The layout of the contract as it is in the working tree, one line per slot user.
layout() {
    local json
    # An artifact built before `extra_output` asked for layouts lacks one; rebuild once.
    json=$(cd "$ROOT_DIR/solidity" && forge inspect "src/$CONTRACT.sol:$CONTRACT" storageLayout --json 2>/dev/null) \
        || json=$(cd "$ROOT_DIR/solidity" && forge build --force > /dev/null \
            && forge inspect "src/$CONTRACT.sol:$CONTRACT" storageLayout --json)
    jq -r '
        .types as $t
        | (.storage[] | "\(.label) \(.slot) \(.offset) \($t[.type].label)"),
          ($t | to_entries[] | select(.value.members) | .value as $s
             | $s.members[] | "\($s.label).\(.label) \(.slot) \(.offset) \($t[.type].label)")
    ' <<< "$json" | sort
}

if [ "$MODE" = "write" ]; then
    mkdir -p "$(dirname "$SNAPSHOT")"
    layout > "$SNAPSHOT"
    echo "Recorded $CONTRACT storage layout: ${SNAPSHOT#"$ROOT_DIR"/}" >&2
    exit 0
fi

if [ ! -f "$SNAPSHOT" ]; then
    echo "❌ No storage layout recorded for $CONTRACT on chain $CHAIN_ID (${SNAPSHOT#"$ROOT_DIR"/})." >&2
    echo "   Check out the commit that is deployed there and run:" >&2
    echo "     ./scripts/layout.sh write $CONTRACT $CHAIN_ID" >&2
    exit 1
fi

CURRENT="$(layout)"
BROKEN=$(comm -23 "$SNAPSHOT" <(echo "$CURRENT"))
if [ -n "$BROKEN" ]; then
    echo "❌ $CONTRACT no longer matches the storage layout live on chain $CHAIN_ID." >&2
    echo "   These slots were moved, retyped, renamed or removed (name slot offset type):" >&2
    echo "$BROKEN" | sed 's/^/     /' >&2
    echo "   An upgrade would read the existing data as something else. Only append." >&2
    exit 1
fi
echo "✅ $CONTRACT storage layout is compatible with chain $CHAIN_ID." >&2
