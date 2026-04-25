#!/usr/bin/env bash
# Wire L1 + L2 after deploys. Three operator concerns handled here:
#
#   (a) L1 `hook_caller` must be the Move-hook intermediate sender derived
#       from the L2 side's cosmos address + channel. Without it, the L2 ->
#       L1 liquidate/withdraw path reverts with E_UNAUTHORIZED.
#   (b) L2 `HOOK_CALLER_ROLE` must be granted to the EVM-hook intermediate
#       sender. Same derivation in reverse (L1 sender + channel).
#   (c) The real production `mLP` ERC20 on L2 is auto-deployed by the
#       bank->erc20 converter when mLP first bridges. We pick it up from
#       the packet's `erc20_created` event and call setMLPToken. The
#       mock is still deployed as a test-mode fallback.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require cast
require initiad
require minitiad

MERIDIAN_ADDR=$(cat "$L1_MERIDIAN_ADDR_FILE")
IBC_RECEIVER=$(jq -r '.[] | select(.name=="IBCReceiver") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
COLL_MGR=$(jq -r '.[] | select(.name=="CollateralManager") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
LIQ_ENGINE=$(jq -r '.[] | select(.name=="LiquidationEngine") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
DEPLOYER_PK=$(cat "$STATE_DIR/l2_deployer_privkey")
PK="0x${DEPLOYER_PK}"
ETH_RPC="http://127.0.0.1:$L2_ETH_PORT"
CHANNEL=$(cat "$IBC_CHANNEL_FILE")
L1_ADMIN_ADDR=$(jq -r '.address' "$STATE_DIR/l1_key_${L1_ADMIN_KEY}.json")
L2_DEPLOYER_ADDR=$(jq -r '.address' "$STATE_DIR/l2_key_${L2_DEPLOYER_KEY}.json")

# ------------------------------------------------------------
# 1. Derive both hook intermediate senders
# ------------------------------------------------------------
info "deriving IBC hook intermediate senders"

# L1 -> L2 direction: EVM hook middleware, prefix 'ibc-evm-hook-intermediary'
read HOOK_L2_A HOOK_L2_B <<EOF
$(python3 - "$CHANNEL" "$L1_ADMIN_ADDR" <<'PY'
import hashlib, sys
channel, sender = sys.argv[1], sys.argv[2]
th = hashlib.sha256(b"ibc-evm-hook-intermediary").digest()
full = hashlib.sha256(th + f"{channel}/{sender}".encode()).digest()
print("0x" + full[:20].hex(), "0x" + full[-20:].hex())
PY
)
EOF
echo "$HOOK_L2_A" > "$IBC_HOOK_CALLER_L2"
info "  L2 EVM-hook intermediate sender (first 20B): $HOOK_L2_A"

# L2 -> L1 direction: Move hook middleware, prefix 'ibc-move-hook-intermediary'
HOOK_L1_BECH=$(python3 - "$CHANNEL" "$L2_DEPLOYER_ADDR" <<'PY'
import hashlib, sys, os
channel, sender = sys.argv[1], sys.argv[2]
th = hashlib.sha256(b"ibc-move-hook-intermediary").digest()
full = hashlib.sha256(th + f"{channel}/{sender}".encode()).digest()
# Cosmos SDK v0.50 uses all 32 bytes for module-derived accounts
# but 20 bytes for account addresses. Try 20B first.
print(full[:20].hex())
PY
)
echo "$HOOK_L1_BECH" > "$IBC_HOOK_CALLER_L1"
info "  L1 Move-hook intermediate sender (hex 20B):  $HOOK_L1_BECH"

# ------------------------------------------------------------
# 2. Deploy L2 contracts wiring + roles
# ------------------------------------------------------------
info "L2 role grants"
MROLE=$(cast keccak "MANAGER_ROLE")
PROLE=$(cast keccak "POOL_ADMIN_ROLE")
RROLE=$(cast keccak "REPORTER_ROLE")
HOOK_ROLE=$(cast keccak "HOOK_CALLER_ROLE")
POOL=$(jq -r '.[] | select(.name=="LendingPool") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
ORACLE=$(jq -r '.[] | select(.name=="YieldOracle") | .addr' "$L2_DEPLOYED_ADDRS_FILE")

for target in $POOL $LIQ_ENGINE $IBC_RECEIVER; do
    cast send $COLL_MGR "grantRole(bytes32,address)" $MROLE $target \
        --private-key $PK --rpc-url $ETH_RPC --legacy >/dev/null
done
cast send $POOL "grantRole(bytes32,address)" $PROLE $LIQ_ENGINE \
    --private-key $PK --rpc-url $ETH_RPC --legacy >/dev/null
cast send $ORACLE "grantRole(bytes32,address)" $RROLE $IBC_RECEIVER \
    --private-key $PK --rpc-url $ETH_RPC --legacy >/dev/null

info "  granting HOOK_CALLER_ROLE to intermediate sender"
for ADDR in "$HOOK_L2_A" "$HOOK_L2_B"; do
    cast send "$IBC_RECEIVER" \
        "grantRole(bytes32,address)" "$HOOK_ROLE" "$ADDR" \
        --private-key "$PK" --rpc-url "$ETH_RPC" --legacy >/dev/null
done

# ------------------------------------------------------------
# 3. mLP ERC20: pick up real voucher from a bridging transfer, else mock
# ------------------------------------------------------------
MLP_MODE=${MLP_MODE:-mock}
if [ "$MLP_MODE" = "real" ]; then
    info "mLP: waiting for the first mLP IBC transfer to auto-create voucher ERC20"
    # Operator must have transferred mLP denom via `meridian::deposit` before
    # running this step. Read the voucher from the latest bridged erc20.
    LATEST_DENOM=$(minitiad query erc20 all-erc20-pairs --node "tcp://127.0.0.1:$L2_RPC_PORT" --output json 2>/dev/null | jq -r '.pairs[-1].erc20' || echo "")
    if [ -n "$LATEST_DENOM" ] && [ "$LATEST_DENOM" != "null" ]; then
        MLP=$LATEST_DENOM
        info "  picked up real mLP voucher: $MLP"
    else
        info "  WARNING: no erc20 pairs found, falling back to mock"
        MLP_MODE=mock
    fi
fi

if [ "$MLP_MODE" = "mock" ]; then
    info "mLP: deploying mock ERC20 (MLP_MODE=real to use real voucher)"
    MLP=$(cd "$REPO_ROOT/contracts" && forge create script/Deploy.s.sol:MockLendingToken \
        --rpc-url "$ETH_RPC" --private-key "$PK" --legacy --broadcast 2>&1 | \
        awk '/Deployed to:/ {print $3; exit}')
fi

echo "$MLP" > "$STATE_DIR/l2_mlp_addr"
info "  mLP address: $MLP"

cast send "$IBC_RECEIVER" "setMLPToken(address)" "$MLP" --private-key "$PK" --rpc-url "$ETH_RPC" --legacy >/dev/null
cast send "$COLL_MGR" \
    "configureCollateral(address,uint256,uint256,uint256)" \
    "$MLP" 650000000000000000 1000000000000000000 50000000000000000 \
    --private-key "$PK" --rpc-url "$ETH_RPC" --legacy >/dev/null
cast send "$COLL_MGR" "setPrice(address,uint256)" "$MLP" 1000000000000000000 \
    --private-key "$PK" --rpc-url "$ETH_RPC" --legacy >/dev/null

# ------------------------------------------------------------
# 4. L1 hook_caller + l2_receiver
# ------------------------------------------------------------
info "L1 wiring"
info "  meridian::set_l2_receiver($IBC_RECEIVER)"
initiad tx move execute "$MERIDIAN_ADDR" meridian set_l2_receiver \
    --args "[\"string:$IBC_RECEIVER\"]" \
    --from "$L1_ADMIN_KEY" --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "tcp://127.0.0.1:$L1_RPC_PORT" \
    --gas auto --gas-adjustment 1.4 --fees "1000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes --output json >/dev/null
sleep 4

info "  meridian::set_hook_caller(0x${HOOK_L1_BECH})"
# Pad to 32-byte Move address
HOOK_L1_MOVE=$(printf '0x%024s%s' '' "$HOOK_L1_BECH" | tr ' ' '0')
initiad tx move execute "$MERIDIAN_ADDR" meridian set_hook_caller \
    --args "[\"address:$HOOK_L1_MOVE\"]" \
    --from "$L1_ADMIN_KEY" --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "tcp://127.0.0.1:$L1_RPC_PORT" \
    --gas auto --gas-adjustment 1.4 --fees "1000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes --output json >/dev/null
sleep 4

info "wiring complete"
info "  meridian (L1):       $MERIDIAN_ADDR"
info "  IBCReceiver (L2):    $IBC_RECEIVER"
info "  CollateralManager:   $COLL_MGR"
info "  LiquidationEngine:   $LIQ_ENGINE"
info "  mLP ERC20:           $MLP"
info "  hook_caller (L1):    $HOOK_L1_MOVE"
info "  hook_caller (L2):    $HOOK_L2_A"
