# Level 3 — Testnet deploy

Deploy Meridian to public testnets instead of a local sandbox. Everything from Level 2 still applies; the differences are:

1. No chain bring-up. Point at existing testnet RPCs.
2. No local relayer. Use an existing channel on the testnet (Initia testnet already relays to its own MiniEVMs via community hermes instances).
3. Funded keys required — both chains' gas denoms need real balance on a non-local keyring.

## Prerequisites

- A funded key on Initia testnet (faucet: https://faucet.testnet.initia.xyz)
- An own MiniEVM rollup deployed via `minitia launcher` OR access to a public MiniEVM testnet with IBC to Initia
- The IBC channel ID connecting your two chains (query via `initiad query ibc channel channels`)
- All the binaries from Level 2 (`initiad`, `minitiad`, `forge`, `cast`, `jq`)

## Files

```
env.sh                       testnet chain IDs, RPC URLs, existing channel
01-fund-check.sh             verify keys have balance on both chains
02-deploy-l1.sh              move deploy + initialize
03-deploy-l2.sh              forge script deploy + verify on block explorer
04-wire-contracts.sh         roles + hook caller + setMLPToken
05-test-deposit.sh           same as L2 08-test-deposit.sh but with real RPCs
06-verify-state.sh           cross-chain state check
```

Scripts 01-04 map 1:1 to Level 2's 05-07; 05-06 map to Level 2's 08-09. There's no 01/02/03/04 equivalent because the chains and relayer already exist on testnet.

## Why no teardown

Testnet state is permanent. If you deploy the Move module then later need to change it, you must either:

- Publish a new version at a different admin address (leaks old state)
- Use `object_code_deployment::upgrade_v2` if you deployed via `deploy-object`

Plan for this before running `02-deploy-l1.sh`. Once published, the module address is baked into L2 contracts and hook caller derivation.
