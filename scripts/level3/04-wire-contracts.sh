#!/usr/bin/env bash
# Grant all roles, compute + grant hook caller role, set L2 receiver on L1,
# configure collateral, setMLPToken.
#
# This mirrors scripts/level2/07-wire-contracts.sh but against testnet RPCs.
# If you want to share code rather than duplicate, the L2 role grants and hook
# caller derivation are identical; L1 tx submission flags differ only in chain-id.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require cast
require initiad

MERIDIAN_ADDR=$(cat "$L1_MERIDIAN_ADDR_FILE")
IBC_RECEIVER=$(jq -r '.[] | select(.name=="IBCReceiver") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
CM=$(jq -r '.[] | select(.name=="CollateralManager") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
POOL=$(jq -r '.[] | select(.name=="LendingPool") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
ENGINE=$(jq -r '.[] | select(.name=="LiquidationEngine") | .addr' "$L2_DEPLOYED_ADDRS_FILE")
ORACLE=$(jq -r '.[] | select(.name=="YieldOracle") | .addr' "$L2_DEPLOYED_ADDRS_FILE")

PK="0x${L2_DEPLOYER_KEY_HEX}"
L1_ADMIN_ADDR=$(initiad keys show "$L1_ADMIN_KEY" --keyring-backend test --home "$L1_HOME" --output json | jq -r .address)
L2_DEPLOYER_ADDR=$(cast wallet address --private-key $PK)

info "deriving intermediate senders for channel $IBC_CHANNEL"

read HOOK_L2_A HOOK_L2_B <<EOF
$(python3 - "$IBC_CHANNEL" "$L1_ADMIN_ADDR" <<'PY'
import hashlib, sys
channel, sender = sys.argv[1], sys.argv[2]
th = hashlib.sha256(b"ibc-evm-hook-intermediary").digest()
full = hashlib.sha256(th + f"{channel}/{sender}".encode()).digest()
print("0x" + full[:20].hex(), "0x" + full[-20:].hex())
PY
)
EOF
echo "$HOOK_L2_A" > "$IBC_HOOK_CALLER_L2_FILE"

HOOK_L1_HEX=$(python3 - "$IBC_CHANNEL" "$L2_DEPLOYER_ADDR" <<'PY'
import hashlib, sys
channel, sender = sys.argv[1], sys.argv[2].lower()
th = hashlib.sha256(b"ibc-move-hook-intermediary").digest()
print(hashlib.sha256(th + f"{channel}/{sender}".encode()).digest()[:20].hex())
PY
)
echo "$HOOK_L1_HEX" > "$IBC_HOOK_CALLER_L1_FILE"

info "  hook_caller (L2): $HOOK_L2_A / $HOOK_L2_B"
info "  hook_caller (L1): 0x$HOOK_L1_HEX"

# L2 role grants
MROLE=$(cast keccak "MANAGER_ROLE")
PROLE=$(cast keccak "POOL_ADMIN_ROLE")
RROLE=$(cast keccak "REPORTER_ROLE")
HOOK_ROLE=$(cast keccak "HOOK_CALLER_ROLE")

info "L2 role grants"
for target in $POOL $ENGINE $IBC_RECEIVER; do
    cast send $CM "grantRole(bytes32,address)" $MROLE $target --private-key $PK --rpc-url $L2_ETH_RPC --legacy >/dev/null
done
cast send $POOL "grantRole(bytes32,address)" $PROLE $ENGINE --private-key $PK --rpc-url $L2_ETH_RPC --legacy >/dev/null
cast send $ORACLE "grantRole(bytes32,address)" $RROLE $IBC_RECEIVER --private-key $PK --rpc-url $L2_ETH_RPC --legacy >/dev/null

for ADDR in "$HOOK_L2_A" "$HOOK_L2_B"; do
    cast send $IBC_RECEIVER "grantRole(bytes32,address)" $HOOK_ROLE $ADDR --private-key $PK --rpc-url $L2_ETH_RPC --legacy >/dev/null
done

# mLP: on testnet you almost certainly want the real bridged ERC20, not mock.
# Operator: transfer a small amount of mLP via meridian::deposit FIRST, then
# run this step. It will query the auto-created ERC20.
if [ -n "${MLP_ADDRESS:-}" ]; then
    MLP="$MLP_ADDRESS"
    info "  using MLP_ADDRESS override: $MLP"
else
    info "  querying ERC20 factory for bridged mLP (set MLP_ADDRESS to override)"
    MLP=$(minitiad query erc20 all-erc20-pairs --node "$L2_RPC" --output json 2>/dev/null \
        | jq -r '.pairs[] | select(.denom | startswith("ibc/")) | .erc20' | head -1)
    [ -n "$MLP" ] || die "no bridged ERC20 found - run a deposit first, or set MLP_ADDRESS"
fi
echo "$MLP" > "$STATE_DIR/l2_mlp_addr"
info "  mLP: $MLP"

cast send $IBC_RECEIVER "setMLPToken(address)" $MLP --private-key $PK --rpc-url $L2_ETH_RPC --legacy >/dev/null
cast send $CM "configureCollateral(address,uint256,uint256,uint256)" \
    $MLP 650000000000000000 1000000000000000000 50000000000000000 \
    --private-key $PK --rpc-url $L2_ETH_RPC --legacy >/dev/null
cast send $CM "setPrice(address,uint256)" $MLP 1000000000000000000 \
    --private-key $PK --rpc-url $L2_ETH_RPC --legacy >/dev/null

# L1 wiring
info "L1 wiring"
HOOK_L1_MOVE=$(printf '0x%024s%s' '' "$HOOK_L1_HEX" | tr ' ' '0')

initiad tx move execute "$MERIDIAN_ADDR" meridian set_l2_receiver \
    --args "[\"string:$IBC_RECEIVER\"]" \
    --from "$L1_ADMIN_KEY" --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "$L1_RPC" \
    --gas auto --gas-adjustment 1.5 --fees "2000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes --output json >/dev/null
sleep 8
initiad tx move execute "$MERIDIAN_ADDR" meridian set_hook_caller \
    --args "[\"address:$HOOK_L1_MOVE\"]" \
    --from "$L1_ADMIN_KEY" --chain-id "$L1_CHAIN_ID" --home "$L1_HOME" \
    --keyring-backend test --node "$L1_RPC" \
    --gas auto --gas-adjustment 1.5 --fees "2000000${L1_BOND_DENOM}" \
    --broadcast-mode sync --yes --output json >/dev/null

info "wiring complete"
