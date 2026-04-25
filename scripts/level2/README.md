# Level 2 — Local multi-chain bring-up

Runs Meridian end-to-end locally: Initia L1 + Meridian MiniEVM L2 + Hermes relayer. A user deposits LP on L1, the IBC hook fires, collateral credits on L2, the user borrows.

## Tooling required

Checked automatically by `00-prereqs.sh`:

| Tool | Purpose | Install |
|------|---------|---------|
| `initiad` | L1 node | [initia-labs/initia](https://github.com/initia-labs/initia) — `make install` |
| `minitiad` | L2 MiniEVM node | [initia-labs/minievm](https://github.com/initia-labs/minievm) — `make install` |
| `hermes` | IBC relayer | `cargo install ibc-relayer-cli --bin hermes --locked` |
| `forge` | L2 deploys | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| `jq` | JSON parsing | `brew install jq` |
| `cast` | L2 transactions | comes with forge |

## Run order

```bash
./00-prereqs.sh                   # verify binaries
./01-init-l1.sh                   # genesis + keys + configure L1
./02-init-l2.sh                   # genesis + configure L2 MiniEVM
./03-start-chains.sh              # start both chains in background
./04-setup-relayer.sh             # hermes config, create client/conn/channel
./05-deploy-l1.sh                 # publish meridian Move module
./06-deploy-l2.sh                 # forge script Deploy.s.sol
./07-wire-contracts.sh            # set mLP token, configure collateral, hook_caller, roles
./08-test-deposit.sh              # user deposits LP, IBC relays, mLP credits as collateral
./09-verify-state.sh              # query both chains, confirm state converged
./99-teardown.sh                  # kill chains, clean home dirs
```

## Paths

All state lives under `./_home/`:
- `./_home/l1/` — initiad home
- `./_home/l2/` — minitiad home
- `./_home/hermes/` — hermes config + keys
- `./_home/logs/` — chain + relayer logs
- `./_home/state/` — deployed addresses, channel ids, tx hashes

## Troubleshooting

**"connection refused" from relayer**
Chains aren't fully synced yet. Check `./_home/logs/l1.log` and `l2.log`. Both should reach height > 5 before you run 04.

**"channel creation failed: no light client"**
The client handshake timed out. Increase `clock_drift` in the hermes config, or ensure both chains have produced blocks recently.

**Move publish reverts with `E_ALREADY_INITIALIZED`**
You re-ran 05 against a chain that already has the module. Either skip 05 or run `./99-teardown.sh` and restart.

**L2 `creditCollateral` reverts with AccessControl error**
Step 07 didn't grant `HOOK_CALLER_ROLE` to the hermes intermediate sender. Check the address printed during step 04 matches the role grant in step 07.
