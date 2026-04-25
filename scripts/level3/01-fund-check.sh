#!/usr/bin/env bash
# Verify both keys exist and have funds on both testnets.
#
# Prereqs:
#   1. An Initia testnet key named "$L1_ADMIN_KEY" in the keyring-test of $L1_HOME.
#      Create one: initiad keys add admin-testnet --keyring-backend test
#      Fund it:    https://faucet.testnet.initia.xyz (enter your init1... address)
#
#   2. L2_DEPLOYER_KEY_HEX env var set to a 64-char hex private key.
#      The corresponding EVM address needs fee-denom balance on evm-1.
#      Easiest path: use the same private key your L1 admin derives to (Initia
#      L1 uses coin-type 60 + eth_secp256k1 → the L1 admin cosmos address IS the
#      same account as the L2 EVM address, last 20 bytes hex match).
#
#      Export from initiad keyring:
#        echo "y" | initiad keys export admin-testnet --unarmored-hex --unsafe \
#            --keyring-backend test 2>&1 | grep -oE '^[0-9a-f]{64}$'
#
#      Then IBC-transfer some uinit to your own L2 address (bech32) via
#      ibc-transfer on L1 — the voucher ERC20 + matching fee denom on evm-1
#      will fund gas.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad
require cast
require jq

ADMIN_ADDR=$(initiad keys show "$L1_ADMIN_KEY" \
    --keyring-backend test --home "$L1_HOME" --output json 2>/dev/null \
    | jq -r .address) || die "L1 key '$L1_ADMIN_KEY' not found - create with 'initiad keys add $L1_ADMIN_KEY --keyring-backend test'"

info "L1 admin: $ADMIN_ADDR  (chain: $L1_CHAIN_ID)"
BAL=$(curl -s "$L1_REST/cosmos/bank/v1beta1/balances/$ADMIN_ADDR" \
    | jq -r ".balances[] | select(.denom==\"$L1_BOND_DENOM\") | .amount" 2>/dev/null || echo 0)
BAL=${BAL:-0}
info "  $L1_BOND_DENOM balance: $BAL"
[ "$BAL" = "0" ] && die "L1 admin has no $L1_BOND_DENOM - fund at https://faucet.testnet.initia.xyz"
# 50 INIT minimum for Move publish (~20 INIT gas + 30 INIT safety buffer)
if [ "$BAL" -lt 50000000 ]; then
    info "  WARN: balance < 50 INIT. Publish may fail on gas. Fund more from faucet."
fi

DEPLOYER_ADDR=$(cast wallet address --private-key "0x$L2_DEPLOYER_KEY_HEX")
info "L2 deployer: $DEPLOYER_ADDR  (chain: $L2_CHAIN_ID)"
L2_BAL=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$L2_ETH_RPC")
info "  native balance: $L2_BAL wei"
if [ "$L2_BAL" = "0" ]; then
    info ""
    info "  L2 deployer has no gas. To fund:"
    info "    DEPLOYER_BECH32=\$(initiad debug addr $DEPLOYER_ADDR | awk '/Bech32 Acc/ {print \$NF; exit}')"
    info "    initiad tx ibc-transfer transfer transfer $IBC_CHANNEL_L1 \\"
    info "        \$DEPLOYER_BECH32 100000000uinit --from $L1_ADMIN_KEY ..."
    info "  Wait ~60s for relayers on evm-1 to credit your voucher."
    die "fund L2 deployer first"
fi

info "IBC channel check"
CHAN_INFO=$(curl -s "$L1_REST/ibc/core/channel/v1/channels/$IBC_CHANNEL_L1/ports/transfer" \
    | jq -r '.channel.state' 2>/dev/null || echo "")
info "  L1 $IBC_CHANNEL_L1 state: $CHAN_INFO"
[ "$CHAN_INFO" = "STATE_OPEN" ] || die "L1 channel $IBC_CHANNEL_L1 not OPEN on $L1_CHAIN_ID"

CHAN_L2=$(curl -s "$L2_REST/ibc/core/channel/v1/channels/$IBC_CHANNEL_L2/ports/transfer" \
    | jq -r '.channel.state' 2>/dev/null || echo "")
info "  L2 $IBC_CHANNEL_L2 state: $CHAN_L2"
[ "$CHAN_L2" = "STATE_OPEN" ] || die "L2 channel $IBC_CHANNEL_L2 not OPEN on $L2_CHAIN_ID"

info "all prereqs satisfied - ready to run 02-deploy-l1.sh"
