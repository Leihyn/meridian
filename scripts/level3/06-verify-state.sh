#!/usr/bin/env bash
# Testnet state check. Mirrors level2/09-verify-state.sh.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad
require cast

MERIDIAN_ADDR=$(cat "$L1_MERIDIAN_ADDR_FILE")
CM=$(jq -r '.[] | select(.name=="CollateralManager") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
RECEIVER=$(jq -r '.[] | select(.name=="IBCReceiver") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
ORACLE=$(jq -r '.[] | select(.name=="YieldOracle") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
MLP=$(cat "$STATE_DIR/l2_mlp_addr")
USER_EVM="0x00000000000000000000000000000000000000dE"

echo ""
echo "======================================================"
echo "  Meridian Level 3 testnet state check"
echo "======================================================"
echo ""
echo "L1 (chain-id $L1_CHAIN_ID)"
echo "  meridian module: $MERIDIAN_ADDR"
echo "  channel:         $IBC_CHANNEL"

echo ""
echo "L2 (chain-id $L2_CHAIN_ID)"
echo "  IBCReceiver:   $RECEIVER"
echo "  CollateralManager: $CM"
echo "  mLP ERC20:     $MLP"
echo "  user $USER_EVM:"
echo "    collateral:  $(cast call $CM 'collateralBalances(address,address)(uint256)' $USER_EVM $MLP --rpc-url $L2_ETH_RPC)"
echo "    principal:   $(cast call $ORACLE 'principals(address,address)(uint256)' $USER_EVM $MLP --rpc-url $L2_ETH_RPC)"

HOOK_ROLE=$(cast keccak "HOOK_CALLER_ROLE")
HOOK=$(cat "$IBC_HOOK_CALLER_L2_FILE" 2>/dev/null)
echo ""
echo "IBC auth"
echo "  HOOK_CALLER_ROLE on $HOOK: $(cast call $RECEIVER 'hasRole(bytes32,address)(bool)' $HOOK_ROLE $HOOK --rpc-url $L2_ETH_RPC)"
