#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
PRIVATE_KEY="0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb"
RPC_ENDPOINT="https://sepolia-rollup.arbitrum.io/rpc"
MAX_FEE="0.1"

ADMIN_ADDR="0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6"
USDC_ADDR="0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
SEMAPHORE_ADDR="0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D"

LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

# ==============================================================================
# HELPERS
# All diagnostic output goes to stderr so stdout stays clean for capture.
# ==============================================================================
log_step() {
    echo -e "\n==================================================" >&2
    echo -e "🚀 $1" >&2
    echo -e "==================================================" >&2
}

cast_call() {
    local contract="$1" signature="$2"
    cast call "$contract" "$signature" --rpc-url "$RPC_ENDPOINT"
}

cast_send() {
    local contract="$1" signature="$2"
    shift 2
    cast send "$contract" "$signature" "$@" \
        --rpc-url "$RPC_ENDPOINT" \
        --private-key "$PRIVATE_KEY" > /dev/null
}

deploy_contract() {
    local dir="$1"
    shift

    echo "Deploying from $dir..." >&2

    (cd "$dir" && cargo stylus deploy \
        --private-key "$PRIVATE_KEY" \
        --endpoint "$RPC_ENDPOINT" \
        --max-fee-per-gas-gwei "$MAX_FEE" \
        --constructor-args "$@") > "$LOG_FILE" 2>&1

    cat "$LOG_FILE" >&2

    local address
    address=$(grep -i "deployed code at address:" "$LOG_FILE" \
        | grep -oE '0x[a-fA-F0-9]{40}' \
        | head -n 1 \
        | tr -d '[:space:]')

    if [ -z "$address" ]; then
        echo "❌ Could not extract deployed address from logs." >&2
        exit 1
    fi

    echo "✅ Deployed: $address" >&2
    echo "$address"
}
# ==============================================================================
# DEPLOYMENT SEQUENCE
# ==============================================================================
echo "=========================================" >&2
echo " Starting Contract Deployment Sequence"   >&2
echo "=========================================" >&2

# # 1. Settlement Registry
# log_step "[1/5] Deploying Settlement Registry"
# SETTLEMENT_REGISTRY_ADDRESS=$(deploy_contract \
#     "./SettlementRegistry" \
#     "$ADMIN_ADDR" "$USDC_ADDR" "$SEMAPHORE_ADDR")

# 2. Schema Registry
log_step "[1/4] Deploying Schema Registry"
SCHEMA_REGISTRY_ADDRESS=$(deploy_contract \
    "./SchemaRegistry" \
    "$ADMIN_ADDR")

echo "Verifying Schema Registry admin..." >&2
cast_call "$SCHEMA_REGISTRY_ADDRESS" "getAdmin()(address)"

# 3. Datasource Registry  (schema reg first, then settlement reg)
log_step "[2/4] Deploying Datasource Registry"
DATASOURCE_REGISTRY_ADDRESS=$(deploy_contract \
    "./DatasourceRegistry" \
    "$SCHEMA_REGISTRY_ADDRESS")

# 4. Bind Datasource Registry → Schema Registry
log_step "[3/4] Registering Datasource Registry in Schema Registry"
cast_send "$SCHEMA_REGISTRY_ADDRESS" \
    "setDataSourceRegistry(address)" \
    "$DATASOURCE_REGISTRY_ADDRESS"

echo "Verifying binding..." >&2
cast_call "$SCHEMA_REGISTRY_ADDRESS" "getDataSourceRegistry()(address)"

# ==============================================================================
# SUMMARY
# ==============================================================================
echo -e "\n=========================================" >&2
echo " 🎉 All steps completed successfully!"     >&2
echo "=========================================" >&2
echo "Schema Registry:     $SCHEMA_REGISTRY_ADDRESS"     >&2
echo "Datasource Registry: $DATASOURCE_REGISTRY_ADDRESS" >&2
echo "=========================================" >&2