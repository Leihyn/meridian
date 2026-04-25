#!/usr/bin/env bash
# Configure hermes, create IBC client/connection/channel between L1 and L2.
# The channel uses the `transfer` port with hook middleware enabled on both ends.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require hermes

info "writing hermes config to $HERMES_HOME/config.toml"
mkdir -p "$HERMES_HOME"

cat > "$HERMES_HOME/config.toml" <<EOF
[global]
log_level = "info"

[mode.clients]
enabled = true
refresh = true
misbehaviour = true

[mode.connections]
enabled = true

[mode.channels]
enabled = true

[mode.packets]
enabled = true
clear_interval = 100
clear_on_start = true
tx_confirmation = true

[rest]
enabled = false
host = "127.0.0.1"
port = 3000

[telemetry]
enabled = false
host = "127.0.0.1"
port = 3001

[[chains]]
id = "$L1_CHAIN_ID"
rpc_addr = "http://127.0.0.1:$L1_RPC_PORT"
grpc_addr = "http://127.0.0.1:$L1_GRPC_PORT"
event_source = { mode = "push", url = "ws://127.0.0.1:$L1_RPC_PORT/websocket", batch_delay = "500ms" }
rpc_timeout = "10s"
account_prefix = "init"
key_name = "hermes-l1"
store_prefix = "ibc"
default_gas = 500000
max_gas = 10000000
gas_price = { price = 0.15, denom = "$L1_BOND_DENOM" }
gas_multiplier = 1.2
max_msg_num = 30
max_tx_size = 2097152
clock_drift = "30s"
max_block_time = "30s"
trusting_period = "3days"
trust_threshold = { numerator = "1", denominator = "3" }
address_type = { derivation = "ethermint", proto_type = { pk_type = "/initia.crypto.v1beta1.ethsecp256k1.PubKey" } }

[[chains]]
id = "$L2_CHAIN_ID"
rpc_addr = "http://127.0.0.1:$L2_RPC_PORT"
grpc_addr = "http://127.0.0.1:$L2_GRPC_PORT"
event_source = { mode = "push", url = "ws://127.0.0.1:$L2_RPC_PORT/websocket", batch_delay = "500ms" }
rpc_timeout = "10s"
account_prefix = "init"
key_name = "hermes-l2"
store_prefix = "ibc"
default_gas = 500000
max_gas = 10000000
gas_price = { price = 0, denom = "ugas" }
gas_multiplier = 1.2
max_msg_num = 30
max_tx_size = 2097152
clock_drift = "30s"
max_block_time = "30s"
trusting_period = "3days"
trust_threshold = { numerator = "1", denominator = "3" }
address_type = { derivation = "ethermint", proto_type = { pk_type = "/initia.crypto.v1beta1.ethsecp256k1.PubKey" } }
EOF

info "generating fresh relayer keys and funding them"
# Fresh random keys per chain, then bank-send from admin/deployer so the
# relayer has gas on both sides. Avoids HD-path mismatches between initiad
# and hermes.

# Generate fresh keys via initiad/minitiad (so address derivation matches),
# capture the mnemonic, then import to hermes via mnemonic-file.

# If a previous run saved a valid JSON (with mnemonic), reuse it.
# Otherwise purge any stale keyring entry and regenerate.
if ! jq -e '.mnemonic' "$STATE_DIR/hermes-l1-key.json" >/dev/null 2>&1; then
    echo "y" | initiad keys delete hermes-l1 \
        --keyring-backend test --home "$L1_HOME" 2>/dev/null || true
    initiad keys add hermes-l1 \
        --keyring-backend test --home "$L1_HOME" --output json \
        > "$STATE_DIR/hermes-l1-key.json" 2>/dev/null
fi
HERMES_L1_ADDR=$(jq -r .address "$STATE_DIR/hermes-l1-key.json")
HERMES_L1_MNEM=$(jq -r .mnemonic "$STATE_DIR/hermes-l1-key.json")

if ! jq -e '.mnemonic' "$STATE_DIR/hermes-l2-key.json" >/dev/null 2>&1; then
    echo "y" | minitiad keys delete hermes-l2 \
        --keyring-backend test --home "$L2_HOME" 2>/dev/null || true
    minitiad keys add hermes-l2 \
        --keyring-backend test --home "$L2_HOME" --coin-type 60 --output json \
        > "$STATE_DIR/hermes-l2-key.json" 2>/dev/null
fi
HERMES_L2_ADDR=$(jq -r .address "$STATE_DIR/hermes-l2-key.json")
HERMES_L2_MNEM=$(jq -r .mnemonic "$STATE_DIR/hermes-l2-key.json")

# Import into hermes
echo "$HERMES_L1_MNEM" > "$STATE_DIR/hermes-l1.mnem"
echo "$HERMES_L2_MNEM" > "$STATE_DIR/hermes-l2.mnem"
hermes --config "$HERMES_HOME/config.toml" keys add \
    --chain "$L1_CHAIN_ID" --mnemonic-file "$STATE_DIR/hermes-l1.mnem" \
    --key-name hermes-l1 --hd-path "m/44'/60'/0'/0/0" --overwrite >/dev/null
hermes --config "$HERMES_HOME/config.toml" keys add \
    --chain "$L2_CHAIN_ID" --mnemonic-file "$STATE_DIR/hermes-l2.mnem" \
    --key-name hermes-l2 --hd-path "m/44'/60'/0'/0/0" --overwrite >/dev/null

info "  hermes-l1: $HERMES_L1_ADDR"
info "  hermes-l2: $HERMES_L2_ADDR"

info "funding relayer on L1"
initiad tx bank send "$L1_ADMIN_KEY" "$HERMES_L1_ADDR" \
    "10000000000${L1_BOND_DENOM}" \
    --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "tcp://127.0.0.1:$L1_RPC_PORT" \
    --gas auto --gas-adjustment 1.4 --fees "1000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes --output json >/dev/null
sleep 5

info "funding relayer on L2"
minitiad tx bank send "$L2_DEPLOYER_KEY" "$HERMES_L2_ADDR" \
    "10000000000GAS" \
    --chain-id "$L2_CHAIN_ID" --home "$L2_HOME" \
    --keyring-backend test --node "tcp://127.0.0.1:$L2_RPC_PORT" \
    --gas auto --gas-adjustment 1.4 --fees "1000000GAS" \
    --broadcast-mode sync --yes --output json >/dev/null
sleep 5

info "creating light clients + connection"
hermes --config "$HERMES_HOME/config.toml" \
    create connection --a-chain "$L1_CHAIN_ID" --b-chain "$L2_CHAIN_ID" \
    2>&1 | tee "$LOGS_DIR/hermes-connection.log"

# Extract the connection id
CONN_ID=$(grep -oE 'ConnectionId\("[^"]+"\)' "$LOGS_DIR/hermes-connection.log" | \
    head -1 | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$CONN_ID" ] || die "failed to parse connection id"
echo "$CONN_ID" > "$IBC_CONN_FILE"
info "  connection: $CONN_ID"

info "creating transfer channel (with hook middleware)"
hermes --config "$HERMES_HOME/config.toml" \
    create channel --a-chain "$L1_CHAIN_ID" \
    --a-connection "$CONN_ID" \
    --a-port transfer --b-port transfer \
    --channel-version ics20-1 \
    2>&1 | tee "$LOGS_DIR/hermes-channel.log"

CHANNEL_ID=$(grep -oE 'ChannelId\("channel-[0-9]+"\)' "$LOGS_DIR/hermes-channel.log" | \
    head -1 | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$CHANNEL_ID" ] || die "failed to parse channel id"
echo "$CHANNEL_ID" > "$IBC_CHANNEL_FILE"
info "  channel: $CHANNEL_ID"

info "deriving IBC hook intermediate senders"
# The hook middleware forwards packets as a deterministic intermediate sender
# address derived from (channel, port, original_sender). Query the middleware
# on both sides to learn the address it will use.
#
# Initia exposes a gRPC endpoint for this; fall back to the computed default
# if the RPC fails (for hackathon scope).
info "  (compute hook callers manually — see comment below)"

# TODO(production): query the actual derived hook sender via
#   hermes tx raw query-intermediate-sender or the chain's hook RPC.
# For now write placeholders so subsequent scripts don't crash;
# operator must update these before running 08-test-deposit.sh.
echo "init1hook_caller_l2_placeholder" > "$IBC_HOOK_CALLER_L2"
echo "init1hook_caller_l1_placeholder" > "$IBC_HOOK_CALLER_L1"

info "starting hermes in background"
nohup hermes --config "$HERMES_HOME/config.toml" start \
    > "$LOGS_DIR/hermes.log" 2>&1 &
echo $! > "$STATE_DIR/hermes.pid"

info "relayer running. channel=$CHANNEL_ID  connection=$CONN_ID"
