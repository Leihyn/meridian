#!/usr/bin/env bash
# Live yield-path round-trip L1 -> L2.
#
# Exercises meridian::claim_rewards by sending an IBC transfer with a
# recordYield memo. Verifies the L2 YieldOracle picks up the observation.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad
require cast

CM=$(jq -r '.[] | select(.name=="CollateralManager") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
ORACLE=$(jq -r '.[] | select(.name=="YieldOracle") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
RECEIVER=$(jq -r '.[] | select(.name=="IBCReceiver") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
MLP=$(cat "$STATE_DIR/l2_mlp_addr")
ETH_RPC="http://127.0.0.1:$L2_ETH_PORT"
CHANNEL=$(cat "$IBC_CHANNEL_FILE")

USER_EVM="0x00000000000000000000000000000000000000dE"
REWARD_AMOUNT=100

# selector = keccak256("recordYield(address,uint256)")[:4] = 0x669e1bb6
SELECTOR="669e1bb6"
USER_HEX=$(printf '%064s' "${USER_EVM#0x}" | tr ' ' '0')
AMOUNT_HEX=$(printf '%064x' "$REWARD_AMOUNT")
CALLDATA="0x${SELECTOR}${USER_HEX}${AMOUNT_HEX}"
MEMO='{"evm":{"message":{"contract_addr":"'"$RECEIVER"'","input":"'"$CALLDATA"'"}}}'

BEFORE=$(cast call $ORACLE 'getObservationCount(address,address)(uint256)' $USER_EVM $MLP --rpc-url $ETH_RPC | awk '{print $1}')
info "observations before: $BEFORE"

info "sending IBC transfer with recordYield memo"
initiad tx ibc-transfer transfer transfer "$CHANNEL" "$RECEIVER" 1${L1_BOND_DENOM} \
    --memo "$MEMO" \
    --from "$L1_ADMIN_KEY" --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "tcp://127.0.0.1:$L1_RPC_PORT" \
    --gas auto --gas-adjustment 1.4 --fees "1000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes \
    --packet-timeout-timestamp 600000000000 2>&1 | grep -E "^(code|txhash):"

EXPECTED=$((BEFORE + 1))
info "waiting up to 120s for observation count to reach $EXPECTED"
for i in $(seq 1 60); do
    NOW=$(cast call $ORACLE 'getObservationCount(address,address)(uint256)' $USER_EVM $MLP --rpc-url $ETH_RPC 2>/dev/null | awk '{print $1}')
    if [ "$NOW" = "$EXPECTED" ]; then
        info "SUCCESS: YieldOracle recorded observation (count=$NOW)"
        exit 0
    fi
    sleep 2
done

echo "TIMEOUT: observation count did not advance"
exit 1
