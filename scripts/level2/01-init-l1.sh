#!/usr/bin/env bash
# Initialize a local single-validator Initia L1 chain.
# Creates genesis, funds accounts, sets custom ports, enables IBC hooks.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad

info "wiping $L1_HOME"
rm -rf "$L1_HOME"

info "init chain"
initiad init meridian-local \
    --chain-id "$L1_CHAIN_ID" \
    --home "$L1_HOME" >/dev/null

info "create keys (keyring-test)"
for k in "$L1_ADMIN_KEY" "$L1_USER_KEY" "$L1_VALIDATOR_KEY"; do
    initiad keys add "$k" \
        --keyring-backend test \
        --home "$L1_HOME" \
        --output json > "$STATE_DIR/l1_key_${k}.json" 2>/dev/null
done

ADMIN_ADDR=$(jq -r '.address' "$STATE_DIR/l1_key_${L1_ADMIN_KEY}.json")
USER_ADDR=$(jq -r '.address' "$STATE_DIR/l1_key_${L1_USER_KEY}.json")
VAL_ADDR=$(jq -r '.address' "$STATE_DIR/l1_key_${L1_VALIDATOR_KEY}.json")

info "  admin     $ADMIN_ADDR"
info "  user      $USER_ADDR"
info "  validator $VAL_ADDR"

# Move publishes at the admin address. Initia's Move VM expects 32-byte
# addresses; the cosmos-SDK account address is 20 bytes, so left-pad.
HEX20=$(initiad debug addr "$ADMIN_ADDR" 2>&1 | \
    awk '/Address \(hex\)/ {print tolower($NF); exit}')
[ -n "$HEX20" ] || die "could not derive admin hex addr"
printf '0x%024s%s\n' '' "$HEX20" | tr ' ' '0' > "$L1_MERIDIAN_ADDR_FILE"
info "  admin 32-byte hex: $(cat "$L1_MERIDIAN_ADDR_FILE")"

info "fund genesis accounts"
for addr in "$ADMIN_ADDR" "$USER_ADDR" "$VAL_ADDR"; do
    initiad genesis add-genesis-account "$addr" \
        "100000000000000${L1_BOND_DENOM}" \
        --home "$L1_HOME" >/dev/null
done

info "genesis validator tx"
initiad genesis gentx "$L1_VALIDATOR_KEY" \
    "1000000000${L1_BOND_DENOM}" \
    --chain-id "$L1_CHAIN_ID" \
    --keyring-backend test \
    --home "$L1_HOME" >/dev/null

initiad genesis collect-gentxs --home "$L1_HOME" >/dev/null

info "patch config.toml (ports + minimum gas)"
CFG="$L1_HOME/config/config.toml"
APP="$L1_HOME/config/app.toml"

# Laddr overrides
sed -i.bak \
    -e "s#laddr = \"tcp://127.0.0.1:26657\"#laddr = \"tcp://127.0.0.1:$L1_RPC_PORT\"#" \
    -e "s#laddr = \"tcp://0.0.0.0:26656\"#laddr = \"tcp://0.0.0.0:$L1_P2P_PORT\"#" \
    "$CFG"

sed -i.bak \
    -e "s#address = \"tcp://localhost:1317\"#address = \"tcp://127.0.0.1:$L1_API_PORT\"#" \
    -e "s#address = \"localhost:9090\"#address = \"127.0.0.1:$L1_GRPC_PORT\"#" \
    -e "s#minimum-gas-prices = \"\"#minimum-gas-prices = \"0.15${L1_BOND_DENOM}\"#" \
    "$APP"

# versiondb requires a rocksdb-enabled build; most pre-built initiad
# binaries are not compiled with it. Disable unconditionally.
perl -i -pe 's/^(enable = true)$/enable = false/g if /^\[versiondb\]/../^\[/' "$APP"

# Register a test LP coin for Enshrined Liquidity so `meridian::deposit`
# can actually run end-to-end. On production the LP would be a real DEX
# pair token — here we seed a synthetic `ulp` and give the user a supply.
#
# Three things must line up for staking::delegate to accept it:
#   (a) bank.balances holds some ulp for the user
#   (b) bank.denom_metadata has an entry for ulp
#   (c) mstaking.params.bond_denoms includes "ulp"
LP_DENOM="${MERIDIAN_LP_DENOM:-ulp}"
if [ "$LP_DENOM" != "skip" ]; then
    info "registering synthetic LP denom '$LP_DENOM' for Enshrined Liquidity"
    python3 - "$L1_HOME/config/genesis.json" "$USER_ADDR" "$LP_DENOM" <<'PY'
import json, sys
path, user_addr, lp = sys.argv[1], sys.argv[2], sys.argv[3]
g = json.load(open(path))
# (c) add lp to bond_denoms
mstaking = g['app_state']['mstaking']
if lp not in mstaking['params']['bond_denoms']:
    mstaking['params']['bond_denoms'].append(lp)
# (a) give user 1,000,000,000,000 ulp
bank = g['app_state']['bank']
found = False
for bal in bank['balances']:
    if bal['address'] == user_addr:
        bal['coins'].append({'denom': lp, 'amount': '1000000000000'})
        found = True; break
if not found:
    bank['balances'].append({
        'address': user_addr,
        'coins': [{'denom': lp, 'amount': '1000000000000'}],
    })
# Supply is auto-computed from balances when the supply list is empty.
# Populating it partially triggers a validate-genesis mismatch, so leave it.
# (b) metadata
meta_exists = any(m.get('base') == lp for m in bank.get('denom_metadata', []))
if not meta_exists:
    bank['denom_metadata'].append({
        'description': 'Meridian test LP token',
        'denom_units': [{'denom': lp, 'exponent': 0, 'aliases': []}],
        'base': lp, 'display': lp, 'name': 'test LP', 'symbol': 'LP',
    })
json.dump(g, open(path, 'w'), indent=2)
PY
    echo "$LP_DENOM" > "$STATE_DIR/l1_lp_denom"
fi

info "genesis validation"
initiad genesis validate-genesis --home "$L1_HOME" >/dev/null

info "L1 initialized. rpc=$L1_RPC_PORT  grpc=$L1_GRPC_PORT  api=$L1_API_PORT"
info "start with: initiad start --home $L1_HOME"
