# Meridian Operations Runbook

An operator just ran `./scripts/level2/01-init-l1.sh` and the chain won't start. What do they need to know?

This document captures the tribal knowledge that turned a working dev setup into a reliably reproducible one. Every item below came from a real failure during bring-up, not documentation.

## Quick start

```bash
cd scripts/level2
./00-prereqs.sh      # abort early if any binary is missing
./01-init-l1.sh
./02-init-l2.sh
./03-start-chains.sh
./04-setup-relayer.sh
./05-deploy-l1.sh
./06-deploy-l2.sh
./07-wire-contracts.sh
./08-test-deposit.sh
./09-verify-state.sh
```

Each script is idempotent-ish. State lives under `./_home/`. Teardown with `./99-teardown.sh --wipe`.

## Tooling versions that actually work

`initiad v1.4.4`, `minitiad v1.2.15`, `hermes v1.10.5`. Newer Hermes (1.12+) pulls in `penumbra-sdk-proof-params` which tries to download proving keys from GitHub LFS during `cargo install` — times out on flaky networks and abandons the build. Pin to 1.10.5:

```bash
cargo install ibc-relayer-cli --bin hermes --locked --version 1.10.5
```

If `cargo install` still hangs on network errors, set `~/.cargo/config.toml`:

```toml
[registries.crates-io]
protocol = "sparse"

[net]
retry = 10
git-fetch-with-cli = true
```

For `minitiad`, the `make install` build from source will fail on Go module downloads if the user's network is flaky. The binary release from GitHub is faster and deterministic:

```bash
curl -L -C - -o minievm.tar.gz \
  "https://gh-proxy.com/https://github.com/initia-labs/minievm/releases/download/v1.2.15/minievm_v1.2.15_Darwin_aarch64.tar.gz"
tar -xzf minievm.tar.gz && mv minitiad ~/go/bin/
```

The `-C -` flag resumes a partial download; looping `curl -L -C -` handles flaky connections that drop mid-transfer.

## Three non-obvious bridge requirements

### 1. The IBC transfer `receiver` field must equal `msg.ContractAddr`

```go
// minievm/app/ibc-hooks/util.go
if receiver != msg.ContractAddr {
    return errors.Wrapf(channeltypes.ErrInvalidPacket, "receiver is not properly set")
}
```

MiniEVM's hook middleware does a literal string comparison. The `receiver` in `MsgTransfer` must be the **hex `0x...` contract address**, not its bech32 form. The packet is rejected with ack `{"error":"ibc evm hook error: receiver is not properly set: invalid packet"}` if they disagree.

### 2. `ibchooks.params.default_allowed` must be `true` at genesis

Default MiniEVM genesis ships with `default_allowed: false` and an empty ACL — meaning no contract is callable via IBC hooks. The packet relays successfully but the memo is silently ignored. Script `02-init-l2.sh` patches this post-init:

```python
g['app_state']['ibchooks']['params']['default_allowed'] = True
```

In production, replace the blanket allow with an explicit ACL:

```json
{ "params": { "default_allowed": false }, "acls": [
  { "address": "0x5de0...", "allowed": true }
]}
```

Changing this on a running chain requires a governance proposal or a genesis mutation + full restart. There is no runtime tx for it.

### 3. `HOOK_CALLER_ROLE` must be granted to the derived intermediate sender

When the EVM hook fires, `msg.sender` is NOT the original packet signer. It's an intermediate sender deterministically derived from the channel + original sender:

```python
# Python equivalent of minievm/app/ibc-hooks/util.go::DeriveIntermediateSender
import hashlib
def intermediate_sender(channel: str, sender: str) -> bytes:
    th = hashlib.sha256(b"ibc-evm-hook-intermediary").digest()
    return hashlib.sha256(th + f"{channel}/{sender}".encode()).digest()[:20]
```

For the reverse direction (L2 → L1 via Move hook), prefix is `"ibc-move-hook-intermediary"`.

Grant `HOOK_CALLER_ROLE` to that address on `IBCReceiver` before any packet will succeed:

```bash
cast send "$IBC_RECEIVER" "grantRole(bytes32,address)" \
    $(cast keccak "HOOK_CALLER_ROLE") "$INTERMEDIATE_SENDER" \
    --private-key "$PK" --legacy
```

## HD-path gotcha: Initia uses coin-type 60, not 118

Hermes defaults to the Cosmos standard `m/44'/118'/0'/0/0`. Initia uses `m/44'/60'/0'/0/0` like Ethereum. If you import a mnemonic without overriding the path, the derived address will be different from what initiad produced — and the relayer will fail with `account not found`.

```bash
hermes keys add --chain "$CHAIN" \
    --mnemonic-file /path/mnem \
    --key-name hermes-l1 \
    --hd-path "m/44'/60'/0'/0/0" \
    --overwrite
```

## Address type for Ethermint-style signing

Beyond the HD path, Initia signs with `eth_secp256k1`, not regular secp256k1. Hermes needs this in `config.toml`:

```toml
address_type = { derivation = "ethermint", proto_type = { pk_type = "/initia.crypto.v1beta1.ethsecp256k1.PubKey" } }
```

Without this, packet signatures are rejected by L1 even if the account exists.

## Pre-built initiad binaries lack rocksdb

`initiad start` aborts immediately with:

```
versiondb requires store to be built with the 'rocksdb' build tag
```

The pre-built binaries ship `versiondb.enable = true` in the default config but aren't compiled with rocksdb support. Script `01-init-l1.sh` patches it:

```bash
perl -i -pe 's/^(enable = true)$/enable = false/g if /^\[versiondb\]/../^\[/' "$APP"
```

## Chain reset without losing Move build cache

Stopping and restarting the chain keeps the Move build cache (in `move/build/`) intact, but the chain data gets wiped. If you did a full `./99-teardown.sh --wipe`, the Move package will try to deploy with an old named-addresses value because the compile output is cached under the previous admin's hex. Force a clean Move rebuild:

```bash
rm -rf move/build/
initiad move build --named-addresses "meridian=$(cat _home/state/l1_meridian_address)"
```

The `05-deploy-l1.sh` script passes `--build` to `move deploy` which forces this, but if you publish manually, remember the rebuild step.

## Cargo lock file wedges a second install

A failed `cargo install` holds `~/.cargo/.package-cache` even after the top-level cargo exits. A follow-up install blocks on:

```
Blocking waiting for file lock on package cache
```

Kill any residual cargo process with `pkill -f 'cargo install'` before retrying.

## Useful IBC queries

```bash
# Pending packets on L1 (after sending, before hermes relays)
initiad query ibc channel packet-commitments transfer channel-0 \
    --node tcp://127.0.0.1:26657

# Relayed packet receipt on L2
minitiad query txs --query "recv_packet.packet_sequence=N" \
    --node tcp://127.0.0.1:27657 --output json \
    | jq '.txs[-1].events[] | select(.type=="write_acknowledgement") | .attributes[]'

# Hermes live status
hermes --config _home/hermes/config.toml query channel end \
    --chain meridian-l1-local --port transfer --channel channel-0
```

## Troubleshooting

**"connection refused" when hermes starts**
L1 or L2 isn't accepting RPC connections yet. Check `_home/logs/l1.log` / `l2.log` — chains need a few seconds past `first block produced`. `03-start-chains.sh` already polls for height > 5 before exiting.

**"VM aborted: code=4" on a withdraw/liquidate packet**
`meridian::withdraw` rejected the caller. The intermediate sender from `DeriveIntermediateSender` doesn't match `MeridianState.hook_caller`. Recompute (same formula, prefix `ibc-move-hook-intermediary`), then `meridian::set_hook_caller(admin, new_caller)`.

**Packet relays but ack is `{"error":"ibc evm hook error: Reverted"}`**
The hook called IBCReceiver but the contract reverted. Most likely cause: `HOOK_CALLER_ROLE` is not granted to the intermediate sender on the IBCReceiver. Less likely: the calldata doesn't decode to a valid function selector (check `build_credit_collateral_memo` is producing the expected bytes).

**`AccessControl: account is missing role` on role-gated calls**
The deploy script's `grantRole` calls reported as "failed" in Forge but actually reverted silently because of a MiniEVM-specific tx wrapper quirk. Re-run the role grants individually — `07-wire-contracts.sh` does this explicitly.

**`--unarmored-hex` interactive confirmation in scripts**
`minitiad keys export ... --unarmored-hex --unsafe` prompts `[y/N]` for confirmation. Pipe `echo "y"`:

```bash
echo "y" | minitiad keys export deployer --unarmored-hex --unsafe ... 2>&1 | grep -oE '^[0-9a-f]{64}$'
```

Note the key goes to `stderr`, not stdout — redirect accordingly.

**`go install` hangs on `proxy.golang.org`**
Network connection reset by peer. Fall back to direct git clone (`GOPROXY=direct`) or use `https://goproxy.cn` as a mirror. Loop the download with `curl -C -` if the connection drops mid-transfer.
