#!/usr/bin/env bash
# Initialize a local Meridian MiniEVM L2 chain.
# Template: the exact flags depend on the minitiad version. Adjust as needed.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require minitiad

info "wiping $L2_HOME"
rm -rf "$L2_HOME"

info "init chain"
minitiad init meridian-l2 \
    --chain-id "$L2_CHAIN_ID" \
    --home "$L2_HOME" >/dev/null

info "create keys"
for k in "$L2_DEPLOYER_KEY" "$L2_LENDER_KEY" "$L2_USER_KEY"; do
    minitiad keys add "$k" \
        --keyring-backend test \
        --home "$L2_HOME" \
        --coin-type 60 \
        --output json > "$STATE_DIR/l2_key_${k}.json" 2>/dev/null
done

DEPLOYER_ADDR=$(jq -r '.address' "$STATE_DIR/l2_key_${L2_DEPLOYER_KEY}.json")
LENDER_ADDR=$(jq -r '.address' "$STATE_DIR/l2_key_${L2_LENDER_KEY}.json")
USER_ADDR=$(jq -r '.address' "$STATE_DIR/l2_key_${L2_USER_KEY}.json")

info "  deployer $DEPLOYER_ADDR"
info "  lender   $LENDER_ADDR"
info "  user     $USER_ADDR"

# Export deployer private key for forge scripts (hex, no 0x).
# --unarmored-hex requires an interactive "y" confirmation; feed it.
echo "y" | minitiad keys export "$L2_DEPLOYER_KEY" \
    --unarmored-hex --unsafe \
    --keyring-backend test \
    --home "$L2_HOME" 2> "$STATE_DIR/l2_deployer_privkey" >/dev/null
# minitiad writes the key to stderr, not stdout, so swap streams above.
# Trim any trailing newline / strip the confirmation noise.
grep -oE '^[0-9a-f]{64}$' "$STATE_DIR/l2_deployer_privkey" > "$STATE_DIR/l2_deployer_privkey.tmp" \
    && mv "$STATE_DIR/l2_deployer_privkey.tmp" "$STATE_DIR/l2_deployer_privkey"

info "fund genesis accounts"
for addr in "$DEPLOYER_ADDR" "$LENDER_ADDR" "$USER_ADDR"; do
    minitiad genesis add-genesis-account "$addr" \
        "100000000000000000000000000GAS" \
        --home "$L2_HOME" >/dev/null
done

info "add genesis validator (opchild sequencer)"
# MiniEVM is a rollup; there is no staking module. Instead opchild uses
# a single sequencer designated at genesis.
minitiad genesis add-genesis-validator "$L2_DEPLOYER_KEY" \
    --chain-id "$L2_CHAIN_ID" \
    --keyring-backend test \
    --home "$L2_HOME" >/dev/null

info "patch config.toml + app.toml"
CFG="$L2_HOME/config/config.toml"
APP="$L2_HOME/config/app.toml"

sed -i.bak \
    -e "s#laddr = \"tcp://0.0.0.0:26657\"#laddr = \"tcp://127.0.0.1:$L2_RPC_PORT\"#" \
    -e "s#laddr = \"tcp://0.0.0.0:26656\"#laddr = \"tcp://0.0.0.0:$L2_P2P_PORT\"#" \
    "$CFG"

sed -i.bak \
    -e "s#address = \"tcp://0.0.0.0:1317\"#address = \"tcp://127.0.0.1:1319\"#" \
    -e "s#address = \"0.0.0.0:9090\"#address = \"127.0.0.1:$L2_GRPC_PORT\"#" \
    -e "s#minimum-gas-prices = \"\"#minimum-gas-prices = \"0GAS\"#" \
    "$APP"

# Patch the existing [json-rpc] section rather than appending (minitiad init
# already creates one). Just enforce the address and enable flag.
python3 - "$APP" "$L2_ETH_PORT" <<'PY'
import sys, re
path, port = sys.argv[1], sys.argv[2]
text = open(path).read()

def patch_section(name, entries):
    global text
    pattern = rf'(\[{re.escape(name)}\][^\[]*)'
    m = re.search(pattern, text, re.S)
    if not m: return
    section = m.group(1)
    for key, val in entries.items():
        section = re.sub(rf'^\s*{re.escape(key)}\s*=.*$', f'{key} = {val}',
                         section, count=1, flags=re.M)
    text = text[:m.start(1)] + section + text[m.end(1):]

patch_section("json-rpc", {
    "enable": "true",
    "address": f'"127.0.0.1:{port}"',
})
open(path, 'w').write(text)
PY

# Enable the IBC hooks middleware by default so any contract can be the
# target of an IBC hook memo. In production this would be restricted via ACL.
python3 - "$L2_HOME/config/genesis.json" <<'PY'
import json, sys
p = sys.argv[1]
g = json.load(open(p))
g['app_state']['ibchooks']['params']['default_allowed'] = True
json.dump(g, open(p, 'w'), indent=2)
PY

info "genesis validation"
minitiad genesis validate --home "$L2_HOME" >/dev/null

info "L2 initialized. cosmos-rpc=$L2_RPC_PORT  eth-rpc=$L2_ETH_PORT  grpc=$L2_GRPC_PORT"
info "start with: minitiad start --home $L2_HOME"
