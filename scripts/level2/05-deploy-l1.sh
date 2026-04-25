#!/usr/bin/env bash
# Publish the Meridian Move module on L1 and call initialize().
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad

ADMIN_ADDR=$(jq -r '.address' "$STATE_DIR/l1_key_${L1_ADMIN_KEY}.json")
# Address was persisted by 01-init-l1.sh as 32-byte hex.
ADMIN_HEX=$(cat "$L1_MERIDIAN_ADDR_FILE" 2>/dev/null || echo "")
if [ -z "$ADMIN_HEX" ]; then
    HEX20=$(initiad debug addr "$ADMIN_ADDR" 2>&1 | \
        awk '/Address \(hex\)/ {print tolower($NF); exit}')
    ADMIN_HEX=$(printf '0x%024s%s' '' "$HEX20" | tr ' ' '0')
    echo "$ADMIN_HEX" > "$L1_MERIDIAN_ADDR_FILE"
fi

info "publishing meridian at $ADMIN_HEX"

cd "$MOVE_DIR"

# `move deploy` builds and publishes in one step (CLI subcommand, not tx).
initiad move deploy \
    --build \
    --named-addresses "meridian=$ADMIN_HEX" \
    --from "$L1_ADMIN_KEY" \
    --chain-id "$L1_CHAIN_ID" \
    --home "$L1_HOME" \
    --keyring-backend test \
    --node "tcp://127.0.0.1:$L1_RPC_PORT" \
    --gas auto --gas-adjustment 1.4 \
    --fees "1000000${L1_BOND_DENOM}" \
    --broadcast-mode sync \
    --yes 2>&1 | tee "$STATE_DIR/l1_publish_tx.log"

info "waiting for tx to land"
sleep 6

CHANNEL=$(cat "$IBC_CHANNEL_FILE")

info "calling meridian::initialize(channel=$CHANNEL, port=transfer, l2_receiver=<set after L2 deploy>)"
# This is a chicken-and-egg: initialize needs the L2 IBCReceiver addr.
# We set a placeholder first, then update it via set_hook_caller / re-init
# after 06-deploy-l2.sh produces the real address.
initiad tx move execute \
    "$ADMIN_HEX" meridian initialize \
    --args '["string:'"$CHANNEL"'","string:transfer","string:0x0000000000000000000000000000000000000000"]' \
    --from "$L1_ADMIN_KEY" \
    --chain-id "$L1_CHAIN_ID" \
    --home "$L1_HOME" \
    --keyring-backend test \
    --node "tcp://127.0.0.1:$L1_RPC_PORT" \
    --gas auto --gas-adjustment 1.4 \
    --fees "1000000${L1_BOND_DENOM}" \
    --broadcast-mode sync \
    --yes \
    --output json > "$STATE_DIR/l1_init_tx.json"

info "L1 deploy complete. meridian=$ADMIN_HEX  channel=$CHANNEL"
