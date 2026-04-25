#!/usr/bin/env bash
# Publish meridian.move on the Initia testnet.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad

ADMIN_ADDR=$(initiad keys show "$L1_ADMIN_KEY" \
    --keyring-backend test --home "$L1_HOME" --output json | jq -r .address)
HEX20=$(initiad debug addr "$ADMIN_ADDR" 2>&1 | awk '/Address \(hex\)/ {print tolower($NF); exit}')
ADMIN_HEX=$(printf '0x%024s%s' '' "$HEX20" | tr ' ' '0')
echo "$ADMIN_HEX" > "$L1_MERIDIAN_ADDR_FILE"
info "admin hex: $ADMIN_HEX"

cd "$REPO_ROOT/move"

rm -rf build/
info "publishing meridian module (this takes ~30s on testnet)"
initiad move deploy \
    --build \
    --named-addresses "meridian=$ADMIN_HEX" \
    --from "$L1_ADMIN_KEY" \
    --chain-id "$L1_CHAIN_ID" \
    --home "$L1_HOME" \
    --keyring-backend test \
    --node "$L1_RPC" \
    --gas auto --gas-adjustment 1.5 \
    --fees "2000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes | tee "$STATE_DIR/l1_publish_tx.log"

info "initialize(channel=$IBC_CHANNEL) - l2_receiver placeholder, patched by 04-wire-contracts.sh"
sleep 8
initiad tx move execute "$ADMIN_HEX" meridian initialize \
    --args "[\"string:$IBC_CHANNEL\",\"string:transfer\",\"string:0x0000000000000000000000000000000000000000\"]" \
    --from "$L1_ADMIN_KEY" --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "$L1_RPC" \
    --gas auto --gas-adjustment 1.5 --fees "2000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes --output json > "$STATE_DIR/l1_init_tx.json"

info "L1 deploy complete. meridian=$ADMIN_HEX"
