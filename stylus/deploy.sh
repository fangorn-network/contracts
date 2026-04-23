#!/bin/bash
set -e

# ── Config ────────────────────────────────────────────────────────────────────

PRIVATE_KEY="PK"
ADMIN="0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6"
RPC="https://sepolia-rollup.arbitrum.io/rpc"
MAX_FEE="0.1"

USDC="0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
SEMAPHORE="0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D"

SETTLEMENT_DIR="./SettlementRegistry"
SCHEMA_DIR="./SchemaRegistry"
DS_DIR="./DatasourceRegistry"

# ── Helpers ───────────────────────────────────────────────────────────────────

deploy() {
    local dir=$1
    local constructor_args=$2
    echo "" >&2
    echo "Deploying from $dir..." >&2
    
    if [ ! -d "$dir" ]; then
        echo "Error: Directory $dir not found" >&2
        exit 1
    fi

    pushd "$dir" > /dev/null

    local output
    # Pass args without internal quotes so they expand to multiple CLI arguments
    output=$(cargo stylus deploy \
        --private-key "$PRIVATE_KEY" \
        --endpoint "$RPC" \
        --max-fee-per-gas-gwei "$MAX_FEE" \
        --constructor-args $constructor_args 2>&1)

    echo "$output" >&2

    local addr
    addr=$(echo "$output" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)

    if [ -z "$addr" ]; then
        echo "FAILED: No address returned from stylus deploy" >&2
        exit 1
    fi

    popd > /dev/null
    echo "$addr"
}

send() {
    local contract=$1
    local sig=$2
    shift 2
    echo "  Sending: $sig $@" >&2
    cast send "$contract" "$sig" "$@" \
        --rpc-url "$RPC" \
        --private-key "$PRIVATE_KEY" >&2
}

verify_call() {
    local contract=$1
    local sig=$2
    local expected=$3
    
    if [ -z "$contract" ]; then
        echo "ERROR: Attempted to call empty address. Deployment failed." >&2
        exit 1
    fi

    local result
    result=$(cast call "$contract" "$sig" --rpc-url "$RPC")
    echo "  $sig => $result" >&2
    if [[ -n "$expected" && "${result,,}" != "${expected,,}" ]]; then
        echo "  ERROR: expected $expected, got $result" >&2
        exit 1
    fi
}

# ── Deploy ────────────────────────────────────────────────────────────────────

echo "=== 1. Deploy SettlementRegistry ===" >&2
SETTLEMENT_ADDR=$(deploy "$SETTLEMENT_DIR" "$ADMIN $USDC $SEMAPHORE")
echo "SettlementRegistry: $SETTLEMENT_ADDR" >&2

echo "" >&2
echo "=== 2. Deploy SchemaRegistry ===" >&2
SCHEMA_ADDR=$(deploy "$SCHEMA_DIR" "$ADMIN")
echo "SchemaRegistry: $SCHEMA_ADDR" >&2

echo "Verifying SchemaRegistry admin..." >&2
verify_call "$SCHEMA_ADDR" "getAdmin()(address)" "$ADMIN"

echo "" >&2
echo "=== 3. Deploy DataSourceRegistry ===" >&2
DS_ADDR=$(deploy "$DS_DIR" "$SCHEMA_ADDR $SETTLEMENT_ADDR")
echo "DataSourceRegistry: $DS_ADDR" >&2

# ── Wire ──────────────────────────────────────────────────────────────────────

echo "" >&2
echo "=== 4. Wire SchemaRegistry → DataSourceRegistry ===" >&2
send "$SCHEMA_ADDR" "setDataSourceRegistry(address)" "$DS_ADDR"
echo "Verifying..." >&2
verify_call "$SCHEMA_ADDR" "getDataSourceRegistry()(address)" "$DS_ADDR"

echo "" >&2
echo "=== 5. Wire SettlementRegistry → DataSourceRegistry ===" >&2
send "$SETTLEMENT_ADDR" "setRegistry(address,bool)" "$DS_ADDR" true

# ── Summary ───────────────────────────────────────────────────────────────────

echo "" >&2
echo "=== Deployment complete ===" >&2
echo "" >&2

echo "SETTLEMENT_REGISTRY_ADDRESS=$SETTLEMENT_ADDR"
echo "SCHEMA_REGISTRY_ADDRESS=$SCHEMA_ADDR"
echo "DATA_SOURCE_REGISTRY_ADDRESS=$DS_ADDR"