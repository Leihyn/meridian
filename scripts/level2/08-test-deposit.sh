#!/usr/bin/env bash
# End-to-end: user sends an IBC transfer from L1 with an EVM-hook memo
# targeting IBCReceiver.creditCollateral on L2. Hermes relays the packet,
# the ibchooks middleware parses the memo and invokes the hook.
#
# Three non-obvious operator requirements are enforced here:
#   1. The transfer `receiver` field MUST be the literal hex 0x... contract
#      address, matching `msg.ContractAddr` in the memo. Bech32 is rejected.
#   2. L2 genesis needs `ibchooks.params.default_allowed=true` OR the target
#      contract whitelisted in the ACL. (Set by 02-init-l2.sh.)
#   3. The derived intermediate sender must hold HOOK_CALLER_ROLE on the
#      IBCReceiver. (Set by 07-wire-contracts.sh.)
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad
require cast
require jq

RECEIVER=$(jq -r '.[] | select(.name=="IBCReceiver") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
CM=$(jq -r '.[] | select(.name=="CollateralManager") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
MLP=$(cat "$STATE_DIR/l2_mlp_addr")
CHANNEL=$(cat "$IBC_CHANNEL_FILE")

# Target user + amount on L2. The user is whatever 32-byte-left-padded
# address makes sense for a test; here we pick 0x...dE and 500 wei units.
USER_EVM="0x00000000000000000000000000000000000000dE"
AMOUNT_U64=500

# ABI-encode creditCollateral(address,uint256) calldata:
#   selector  = first 4 bytes of keccak256("creditCollateral(address,uint256)")
#   address   = 32-byte left-padded EVM address
#   amount    = 32-byte big-endian uint256
SELECTOR="2ef35002"  # confirmed via `cast sig "creditCollateral(address,uint256)"`
USER_HEX=$(printf '%064s' "${USER_EVM#0x}" | tr ' ' '0')
AMOUNT_HEX=$(printf '%064x' "$AMOUNT_U64")
CALLDATA="0x${SELECTOR}${USER_HEX}${AMOUNT_HEX}"

MEMO='{"evm":{"message":{"contract_addr":"'"$RECEIVER"'","input":"'"$CALLDATA"'"}}}'

info "target:    $RECEIVER"
info "calldata:  $CALLDATA"
info "memo:      $MEMO"

# Read the starting collateral so we can diff after.
BEFORE=$(cast call "$CM" \
    "collateralBalances(address,address)(uint256)" \
    "$USER_EVM" "$MLP" --rpc-url "http://127.0.0.1:$L2_ETH_PORT" | awk '{print $1}')
info "collateral before: $BEFORE"

info "sending IBC transfer L1 -> L2 with EVM hook memo"
TX=$(initiad tx ibc-transfer transfer transfer "$CHANNEL" "$RECEIVER" 1${L1_BOND_DENOM} \
    --memo "$MEMO" \
    --from "$L1_ADMIN_KEY" --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "tcp://127.0.0.1:$L1_RPC_PORT" \
    --gas auto --gas-adjustment 1.4 --fees "1000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes \
    --packet-timeout-timestamp 600000000000 2>&1 | awk '/^txhash:/ {print $2; exit}')
info "L1 tx: $TX"

EXPECTED=$((BEFORE + AMOUNT_U64))
info "waiting up to 120s for collateral to reach $EXPECTED on L2..."
for i in $(seq 1 60); do
    NOW=$(cast call "$CM" \
        "collateralBalances(address,address)(uint256)" \
        "$USER_EVM" "$MLP" --rpc-url "http://127.0.0.1:$L2_ETH_PORT" 2>/dev/null | awk '{print $1}')
    if [ "$NOW" = "$EXPECTED" ]; then
        info "SUCCESS: collateral = $NOW (hook fired, balance advanced by $AMOUNT_U64)"
        exit 0
    fi
    sleep 2
done

echo ""
echo "TIMEOUT: collateral did not advance within 120s."
echo ""
echo "Debug checklist:"
echo "  hermes log:   tail -n 40 $LOGS_DIR/hermes.log"
echo "  packet ack:   minitiad query txs --query 'recv_packet.packet_src_channel=$CHANNEL' --node tcp://127.0.0.1:$L2_RPC_PORT --output json | jq '.txs[-1].events[] | select(.type==\"write_acknowledgement\") | .attributes[]'"
echo "  role check:   cast call $RECEIVER 'hasRole(bytes32,address)(bool)' \\"
echo "                    \$(cast keccak HOOK_CALLER_ROLE) \$(cat $IBC_HOOK_CALLER_L2) \\"
echo "                    --rpc-url http://127.0.0.1:$L2_ETH_PORT"
exit 1
