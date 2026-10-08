#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Deploys the MembershipRegistry (implementation + ERC-1967 proxy) to Arbitrum
# Sepolia, then sets an app's plan from the app owner's wallet.
#
#   PRIVATE_KEY=<admin key> APP_OWNER_KEY=<app owner key> ./scripts/deploy-membership.sh
#
# Optional: APP (default quorum), PRICE in USDC base units (default 1000000 = $1,
# a placeholder), PERIOD in seconds (default 30 days). Prints the proxy address:
# put it in the SDK's FangornConfig.membershipRegistryContractAddress.
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RPC_ENDPOINT="${RPC_ENDPOINT:-https://sepolia-rollup.arbitrum.io/rpc}"
PRIVATE_KEY="${PRIVATE_KEY:?PRIVATE_KEY (the admin) not set}"
APP_OWNER_KEY="${APP_OWNER_KEY:?APP_OWNER_KEY (the app owner) not set}"
APP="${APP:-quorum}"
PRICE="${PRICE:-1000000}"
PERIOD="${PERIOD:-2592000}"
USDC="${USDC:-0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d}"
SEMAPHORE="${SEMAPHORE:-0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D}"
APP_REGISTRY="${APP_REGISTRY:-0x11d228c4774af3d9cae3b4b6874a12576a1a83ec}"
ADMIN="$(cast wallet address "$PRIVATE_KEY")"

cd "$ROOT_DIR/solidity"
impl=$(forge create src/MembershipRegistry.sol:MembershipRegistry \
    --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" --broadcast | awk '/Deployed to/ {print $3}')
echo "implementation: $impl"
init=$(cast calldata "initialize(address,address,address,address)" "$ADMIN" "$USDC" "$SEMAPHORE" "$APP_REGISTRY")
proxy=$(forge create lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --rpc-url "$RPC_ENDPOINT" --private-key "$PRIVATE_KEY" --broadcast \
    --constructor-args "$impl" "$init" | awk '/Deployed to/ {print $3}')
echo "MembershipRegistry (proxy): $proxy"

app_id=$(cast keccak "$(cast --from-utf8 "$APP")")
cast send "$proxy" "setPlan(bytes32,uint256,uint64)" "$app_id" "$PRICE" "$PERIOD" \
    --rpc-url "$RPC_ENDPOINT" --private-key "$APP_OWNER_KEY" >/dev/null
echo "plan for $APP ($app_id): $(cast call "$proxy" "planOf(bytes32)(uint256,uint64)" "$app_id" --rpc-url "$RPC_ENDPOINT" | tr '\n' ' ')"
