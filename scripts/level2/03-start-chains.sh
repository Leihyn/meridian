#!/usr/bin/env bash
# Start both chains in the background. PIDs written to state/.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require initiad
require minitiad

info "starting L1 (logs: $LOGS_DIR/l1.log)"
nohup initiad start --home "$L1_HOME" > "$LOGS_DIR/l1.log" 2>&1 &
echo $! > "$STATE_DIR/l1.pid"

info "starting L2 (logs: $LOGS_DIR/l2.log)"
nohup minitiad start --home "$L2_HOME" > "$LOGS_DIR/l2.log" 2>&1 &
echo $! > "$STATE_DIR/l2.pid"

info "waiting for both chains to reach height > 5"
wait_for_height() {
    local port=$1 label=$2
    for i in $(seq 1 60); do
        local h
        h=$(curl -s "http://127.0.0.1:$port/status" 2>/dev/null | jq -r '.result.sync_info.latest_block_height // "0"')
        if [ "$h" != "0" ] && [ "$h" -gt 5 ]; then
            info "  $label height=$h"
            return 0
        fi
        sleep 2
    done
    die "$label did not reach height > 5 within 2 minutes (check $LOGS_DIR/${label}.log)"
}

wait_for_height "$L1_RPC_PORT" "l1"
wait_for_height "$L2_RPC_PORT" "l2"

info "both chains producing blocks"
