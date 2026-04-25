#!/usr/bin/env bash
# Verify all Level 2 tooling is installed before we waste time on a partial run.
set -euo pipefail
source "$(dirname "$0")/env.sh"

info "checking prereqs"

MISSING=()
for bin in initiad minitiad hermes forge cast jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        MISSING+=("$bin")
    else
        info "  ok  $bin  -> $(command -v "$bin")"
    fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo "Missing binaries: ${MISSING[*]}"
    echo ""
    echo "Install hints:"
    for m in "${MISSING[@]}"; do
        case "$m" in
            initiad)   echo "  initiad:   git clone https://github.com/initia-labs/initia && cd initia && make install" ;;
            minitiad)  echo "  minitiad:  git clone https://github.com/initia-labs/minievm && cd minievm && make install" ;;
            hermes)    echo "  hermes:    cargo install ibc-relayer-cli --bin hermes --locked" ;;
            forge|cast) echo "  $m:       curl -L https://foundry.paradigm.xyz | bash && foundryup" ;;
            jq)        echo "  jq:        brew install jq" ;;
        esac
    done
    exit 1
fi

info "all prereqs present"
