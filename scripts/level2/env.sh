# Shared environment for Level 2 scripts.
# Source this from every step script: `source ./env.sh`

# ---------- Paths ----------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEVEL2_DIR="$REPO_ROOT/scripts/level2"
HOME_DIR="$LEVEL2_DIR/_home"
L1_HOME="$HOME_DIR/l1"
L2_HOME="$HOME_DIR/l2"
HERMES_HOME="$HOME_DIR/hermes"
LOGS_DIR="$HOME_DIR/logs"
STATE_DIR="$HOME_DIR/state"

mkdir -p "$HOME_DIR" "$LOGS_DIR" "$STATE_DIR"

# ---------- Chain IDs ----------
L1_CHAIN_ID="meridian-l1-local"
L2_CHAIN_ID="meridian-l2-local"

# ---------- Ports ----------
L1_RPC_PORT=26657
L1_P2P_PORT=26656
L1_GRPC_PORT=9090
L1_API_PORT=1317
L1_LCD_PORT=1318

L2_RPC_PORT=27657
L2_P2P_PORT=27656
L2_GRPC_PORT=9190
L2_ETH_PORT=8545

# ---------- Token denoms ----------
L1_BOND_DENOM="uinit"
L1_LP_SYMBOL="move/..."   # filled in after initialize_for_chain by 01
L1_LP_DENOM_FILE="$STATE_DIR/l1_lp_denom"

# ---------- Accounts ----------
# Seeded in 01-init-l1.sh and 02-init-l2.sh; mnemonics live in keyring-test.
L1_ADMIN_KEY="admin"         # Move module publisher + hook_caller target
L1_USER_KEY="user"           # end-user who deposits LP
L1_VALIDATOR_KEY="validator"

L2_DEPLOYER_KEY="deployer"   # deploys Solidity contracts
L2_LENDER_KEY="lender"       # provides pool liquidity
L2_USER_KEY="user"           # corresponds to L1 user

# ---------- Move package ----------
MOVE_DIR="$REPO_ROOT/move"
# Address the Move module is published at. Set to admin's address after key gen in 01.
L1_MERIDIAN_ADDR_FILE="$STATE_DIR/l1_meridian_address"

# ---------- L2 deploy outputs ----------
L2_DEPLOYED_ADDRS_FILE="$STATE_DIR/l2_deployed.json"

# ---------- IBC ----------
IBC_CHANNEL_FILE="$STATE_DIR/ibc_channel"    # e.g. channel-0
IBC_CONN_FILE="$STATE_DIR/ibc_connection"    # e.g. connection-0
IBC_HOOK_CALLER_L1="$STATE_DIR/hook_caller_l1"  # intermediate sender on L1 (for L2->L1 hook auth)
IBC_HOOK_CALLER_L2="$STATE_DIR/hook_caller_l2"  # intermediate sender on L2 (for L1->L2 hook auth)

# ---------- Helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing binary: $1"; }
info() { echo "[level2] $*"; }
