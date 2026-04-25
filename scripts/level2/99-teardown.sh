#!/usr/bin/env bash
# Stop all chains/relayers and wipe home dirs.
set -euo pipefail
source "$(dirname "$0")/env.sh"

info "killing chain + relayer processes"
for pidfile in "$STATE_DIR/l1.pid" "$STATE_DIR/l2.pid" "$STATE_DIR/hermes.pid"; do
    if [ -f "$pidfile" ]; then
        PID=$(cat "$pidfile")
        kill "$PID" 2>/dev/null && info "  killed $PID" || info "  $PID not running"
        rm "$pidfile"
    fi
done

if [ "${1:-}" = "--wipe" ]; then
    info "wiping $HOME_DIR"
    rm -rf "$HOME_DIR"
fi

info "teardown done"
