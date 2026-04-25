# Shared environment for Level 3 (Initia testnet + evm-1 MiniEVM).
# This is wired against PUBLIC endpoints — no chain setup required on your end.
# You still need funded keys: see 01-fund-check.sh for instructions.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEVEL3_DIR="$REPO_ROOT/scripts/level3"
STATE_DIR="$LEVEL3_DIR/_state"
LOGS_DIR="$LEVEL3_DIR/_logs"
mkdir -p "$STATE_DIR" "$LOGS_DIR"

# ---------- L1: Initia testnet (initiation-2) ----------
L1_CHAIN_ID="${L1_CHAIN_ID:-initiation-2}"
L1_RPC="${L1_RPC:-https://rpc.testnet.initia.xyz}"
L1_REST="${L1_REST:-https://lcd.testnet.initia.xyz}"
L1_GRPC="${L1_GRPC:-grpc.testnet.initia.xyz:443}"
L1_BOND_DENOM="${L1_BOND_DENOM:-uinit}"
L1_ADMIN_KEY="${L1_ADMIN_KEY:-admin-testnet}"
L1_HOME="${L1_HOME:-$HOME/.initia}"

# ---------- L2: evm-1 MiniEVM testnet ----------
# Public Initia-hosted MiniEVM rollup. default_allowed=true, so our memos
# pass without requiring ACL governance.
L2_CHAIN_ID="${L2_CHAIN_ID:-evm-1}"
L2_RPC="${L2_RPC:-https://rpc-evm-1.anvil.asia-southeast.initia.xyz}"
L2_REST="${L2_REST:-https://rest-evm-1.anvil.asia-southeast.initia.xyz}"
L2_ETH_RPC="${L2_ETH_RPC:-https://jsonrpc-evm-1.anvil.asia-southeast.initia.xyz}"
L2_DEPLOYER_KEY_HEX="${L2_DEPLOYER_KEY_HEX:?set L2_DEPLOYER_KEY_HEX to the deployer private key hex}"

# evm-1 fee denom (bridged via ERC20 factory). Check current at:
# https://rest-evm-1.anvil.asia-southeast.initia.xyz/cosmos/auth/v1beta1/params
L2_FEE_DENOM="${L2_FEE_DENOM:-evm/2eE7007DF876084d4C74685e90bB7f4cd7c86e22}"
L2_MIN_GAS_PRICE="${L2_MIN_GAS_PRICE:-150000000000}"

# ---------- IBC ----------
# Existing open ICS20 transfer channel: initiation-2 ↔ evm-1
# L1 side: channel-3077  ←→  L2 side: channel-0
IBC_CHANNEL_L1="${IBC_CHANNEL_L1:-channel-3077}"
IBC_CHANNEL_L2="${IBC_CHANNEL_L2:-channel-0}"
IBC_CHANNEL="$IBC_CHANNEL_L1"  # alias for compat with L2 scripts

IBC_HOOK_CALLER_L1_FILE="$STATE_DIR/hook_caller_l1"
IBC_HOOK_CALLER_L2_FILE="$STATE_DIR/hook_caller_l2"

# ---------- Deploy outputs ----------
L1_MERIDIAN_ADDR_FILE="$STATE_DIR/l1_meridian_address"
L2_DEPLOYED_ADDRS_FILE="$STATE_DIR/l2_deployed.json"

# ---------- Helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[level3] $*"; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing binary: $1"; }
