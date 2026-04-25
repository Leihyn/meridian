#!/usr/bin/env bash
# Deploy the Solidity stack to the MiniEVM testnet.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require forge
require jq

MERIDIAN_ADDR=$(cat "$L1_MERIDIAN_ADDR_FILE")

cd "$REPO_ROOT/contracts"

info "forge script Deploy.s.sol -> $L2_ETH_RPC"
PRIVATE_KEY="0x${L2_DEPLOYER_KEY_HEX}" \
L1_MODULE_ADDR="$MERIDIAN_ADDR" \
L1_CHANNEL="$IBC_CHANNEL" \
forge script script/Deploy.s.sol:DeployMeridian \
    --rpc-url "$L2_ETH_RPC" \
    --broadcast \
    --legacy \
    -vv 2>&1 | tee "$LOGS_DIR/l2-deploy.log"

BROADCAST=$(ls -t "$REPO_ROOT/contracts/broadcast/Deploy.s.sol/"*/run-latest.json | head -1)
jq '[.transactions[] | select(.transactionType=="CREATE") | {name: .contractName, addr: .contractAddress}]' \
    "$BROADCAST" > "$L2_DEPLOYED_ADDRS_FILE"

info "deployed addresses:"
jq -r '.[] | "  \(.name): \(.addr)"' "$L2_DEPLOYED_ADDRS_FILE"
