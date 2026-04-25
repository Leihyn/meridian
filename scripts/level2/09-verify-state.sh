#!/usr/bin/env bash
# Cross-check state on both chains after the e2e deposit test.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad
require minitiad
require cast

MERIDIAN_ADDR=$(cat "$L1_MERIDIAN_ADDR_FILE")
CM=$(jq -r '.[] | select(.name=="CollateralManager") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
POOL=$(jq -r '.[] | select(.name=="LendingPool") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
RECEIVER=$(jq -r '.[] | select(.name=="IBCReceiver") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
ORACLE=$(jq -r '.[] | select(.name=="YieldOracle") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
MLP=$(cat "$STATE_DIR/l2_mlp_addr")
CHANNEL=$(cat "$IBC_CHANNEL_FILE")
CONN=$(cat "$IBC_CONN_FILE")
USER_EVM="0x00000000000000000000000000000000000000dE"

RPC="http://127.0.0.1:$L2_ETH_PORT"

echo ""
echo "======================================================"
echo "  Meridian Level 2 — end-to-end state check"
echo "======================================================"

echo ""
echo "L1 (Initia, chain-id $L1_CHAIN_ID)"
echo "--------------------------------"
echo "  height:          $(curl -s http://127.0.0.1:$L1_RPC_PORT/status | jq -r '.result.sync_info.latest_block_height')"
echo "  meridian module: $MERIDIAN_ADDR"
echo "  channel:         $CHANNEL"
echo "  connection:      $CONN"

echo ""
echo "L2 (Meridian MiniEVM, chain-id $L2_CHAIN_ID)"
echo "------------------------------------------"
echo "  height:              $(curl -s http://127.0.0.1:$L2_RPC_PORT/status | jq -r '.result.sync_info.latest_block_height')"
echo "  IBCReceiver:         $RECEIVER"
echo "  CollateralManager:   $CM"
echo "  LendingPool:         $POOL"
echo "  YieldOracle:         $ORACLE"
echo "  mLP ERC20:           $MLP"

echo ""
echo "  user $USER_EVM state:"
echo "    collateral:      $(cast call $CM 'collateralBalances(address,address)(uint256)' $USER_EVM $MLP --rpc-url $RPC)"
echo "    debt:            $(cast call $CM 'debts(address)(uint256)' $USER_EVM --rpc-url $RPC)"
echo "    principal:       $(cast call $ORACLE 'principals(address,address)(uint256)' $USER_EVM $MLP --rpc-url $RPC)"

HOOK_ROLE=$(cast keccak "HOOK_CALLER_ROLE")
HOOK_A=$(cat "$IBC_HOOK_CALLER_L2" 2>/dev/null || echo "0x0")
echo ""
echo "  access control:"
echo "    IBCReceiver HOOK_CALLER_ROLE on derived sender $HOOK_A:"
echo "    $(cast call $RECEIVER 'hasRole(bytes32,address)(bool)' $HOOK_ROLE $HOOK_A --rpc-url $RPC)"

echo ""
echo "  pool metrics:"
echo "    utilization:     $(cast call $POOL 'getUtilization()(uint256)' --rpc-url $RPC)"
echo "    total borrowed:  $(cast call $POOL 'totalBorrowed()(uint256)' --rpc-url $RPC)"

echo ""
echo "IBC channel health"
echo "------------------"
echo "  L1 side state:   $(hermes --config $HERMES_HOME/config.toml query channel end --chain $L1_CHAIN_ID --port transfer --channel $CHANNEL 2>&1 | awk '/state:/{print $2; exit}')"
echo "  L2 side state:   $(hermes --config $HERMES_HOME/config.toml query channel end --chain $L2_CHAIN_ID --port transfer --channel $CHANNEL 2>&1 | awk '/state:/{print $2; exit}')"

echo ""
