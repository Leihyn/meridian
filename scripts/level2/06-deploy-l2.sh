#!/usr/bin/env bash
# Deploy the Solidity stack on L2 via forge script.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require forge

MERIDIAN_ADDR=$(cat "$L1_MERIDIAN_ADDR_FILE")
DEPLOYER_PK=$(cat "$STATE_DIR/l2_deployer_privkey")

info "deploying Meridian contracts to L2 (eth-rpc=http://127.0.0.1:$L2_ETH_PORT)"

cd "$REPO_ROOT/contracts"

# The existing Deploy.s.sol reads $PRIVATE_KEY and L1 module address.
# We override the hardcoded L1 addr via an env var.
PRIVATE_KEY="0x${DEPLOYER_PK}" \
L1_MODULE_ADDR="$MERIDIAN_ADDR" \
L1_CHANNEL=$(cat "$IBC_CHANNEL_FILE") \
forge script script/Deploy.s.sol:DeployMeridian \
    --rpc-url "http://127.0.0.1:$L2_ETH_PORT" \
    --broadcast \
    --legacy \
    -vvv 2>&1 | tee "$LOGS_DIR/l2-deploy.log"

info "extracting addresses from broadcast"
BROADCAST_JSON=$(ls -t "$REPO_ROOT/contracts/broadcast/Deploy.s.sol/"*/run-latest.json 2>/dev/null | head -1)
[ -n "$BROADCAST_JSON" ] || die "broadcast output not found"

# Extract the deployed contract addresses keyed by contract name.
jq '[.transactions[] | select(.transactionType=="CREATE") |
     {name: .contractName, addr: .contractAddress}]' \
    "$BROADCAST_JSON" > "$L2_DEPLOYED_ADDRS_FILE"

info "deployed addresses:"
jq -r '.[] | "  \(.name): \(.addr)"' "$L2_DEPLOYED_ADDRS_FILE"
