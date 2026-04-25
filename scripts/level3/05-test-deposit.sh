#!/usr/bin/env bash
# Same flow as Level 2's 08-test-deposit.sh but against testnet RPCs.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad
require cast

RECEIVER=$(jq -r '.[] | select(.name=="IBCReceiver") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
CM=$(jq -r '.[] | select(.name=="CollateralManager") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
MLP=$(cat "$STATE_DIR/l2_mlp_addr")

USER_EVM="0x00000000000000000000000000000000000000dE"
AMOUNT_U64=500

SELECTOR="2ef35002"
USER_HEX=$(printf '%064s' "${USER_EVM#0x}" | tr ' ' '0')
AMOUNT_HEX=$(printf '%064x' "$AMOUNT_U64")
CALLDATA="0x${SELECTOR}${USER_HEX}${AMOUNT_HEX}"
MEMO='{"evm":{"message":{"contract_addr":"'"$RECEIVER"'","input":"'"$CALLDATA"'"}}}'

BEFORE=$(cast call "$CM" "collateralBalances(address,address)(uint256)" \
    "$USER_EVM" "$MLP" --rpc-url "$L2_ETH_RPC" | awk '{print $1}')
info "collateral before: $BEFORE"

info "sending IBC transfer L1 -> L2 via testnet channel $IBC_CHANNEL"
TX=$(initiad tx ibc-transfer transfer transfer "$IBC_CHANNEL" "$RECEIVER" 1${L1_BOND_DENOM} \
    --memo "$MEMO" \
    --from "$L1_ADMIN_KEY" --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "$L1_RPC" \
    --gas auto --gas-adjustment 1.5 --fees "2000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes \
    --packet-timeout-timestamp 600000000000 2>&1 | awk '/^txhash:/ {print $2; exit}')
info "L1 tx: $TX"

EXPECTED=$((BEFORE + AMOUNT_U64))
info "waiting up to 300s for testnet relayer to deliver (slower than local)"
for i in $(seq 1 150); do
    NOW=$(cast call "$CM" "collateralBalances(address,address)(uint256)" \
        "$USER_EVM" "$MLP" --rpc-url "$L2_ETH_RPC" 2>/dev/null | awk '{print $1}')
    if [ "$NOW" = "$EXPECTED" ]; then
        info "SUCCESS on testnet: collateral $BEFORE -> $NOW"
        exit 0
    fi
    sleep 2
done

echo "TIMEOUT: relayer hasn't delivered in 5min — check testnet relayer status or retry"
exit 1
