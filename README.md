# Meridian

Lend against staked LP that keeps earning yield.

## The Problem

A liquidity provider on Initia has two bad options. Stake LP via Enshrined Liquidity for 8% yield and lock the capital. Or stay liquid and earn nothing. Aave solved this for ETH a decade ago — Meridian solves it for staked LP on Initia.

## The Solution

Deposit LP on Initia L1. Get an `mLP` receipt token that bridges automatically to a Meridian MiniEVM rollup as collateral. Borrow INIT against it. Your underlying LP keeps staking and keeps earning yield for the entire life of the loan.

One pile of capital, two revenue streams.

## How It Works

```
Initia L1 (Move)                Meridian L2 (MiniEVM)
─────────────────               ──────────────────────
deposit(lp_token)
  → stake with validator
  → mint mLP 1:1
  → IBC + EVM-hook memo  ─────▶ creditCollateral()
                                  → CollateralManager
                                  → YieldOracle

                                borrow(amount)
                                  → LendingPool ERC-4626
                                  → health factor check

                                liquidate() if HF < 1
                                  → seize collateral
                                  → IBC + Move-hook memo
meridian::liquidate()    ◀───── 
  → undelegate LP
  → deliver to liquidator
```

Three round-trips. All via IBC with hook middleware on both sides.

## Quick Start (local)

```bash
cd scripts/level2
./00-prereqs.sh          # verify initiad, minitiad, hermes, forge, jq
./01-init-l1.sh          # Initia L1 genesis
./02-init-l2.sh          # MiniEVM L2 genesis
./03-start-chains.sh     # start both chains in background
./04-setup-relayer.sh    # hermes config + open IBC channel
./05-deploy-l1.sh        # publish meridian Move module
./06-deploy-l2.sh        # deploy 7 Solidity contracts
./07-wire-contracts.sh   # roles, hook callers, mLP, prices
./08-test-deposit.sh     # live IBC packet → collateral credited

cd ../../frontend
npm install && npm run dev    # http://localhost:3000
```

## Testnet Deploy

Targets `initiation-2` (Initia testnet) and `evm-1` (MiniEVM testnet) via the existing IBC channel `3077` ↔ `0`.

```bash
cd scripts/level3
# Get a funded testnet key first (see scripts/level3/01-fund-check.sh)
L2_DEPLOYER_KEY_HEX=<your_hex> ./01-fund-check.sh
L2_DEPLOYER_KEY_HEX=<your_hex> ./02-deploy-l1.sh
L2_DEPLOYER_KEY_HEX=<your_hex> ./03-deploy-l2.sh
L2_DEPLOYER_KEY_HEX=<your_hex> ./04-wire-contracts.sh
L2_DEPLOYER_KEY_HEX=<your_hex> ./05-test-deposit.sh
```

## Tested Scope

- **49 automated tests** pass: 8 Move + 41 Foundry
- **Live IBC round-trip** proven: `collateralBalances` advanced via real packet
- **Cross-language calldata consistency**: bytes Move emits decode in Solidity
- **Access control on both ends**: unauthorized callers rejected with the right error codes
- **Liquidation timeout restoration**: failed liquidation IBC packet unwinds L2 state

## Architecture

| Layer | Tech |
|---|---|
| L1 | Initia (Move VM, Cosmos SDK) — `initiad v1.4.4` |
| L2 | Meridian MiniEVM rollup — `minitiad v1.2.15` |
| IBC | Hermes v1.10.5, EVM-hook + Move-hook middleware |
| Contracts | Solidity 0.8.28, OpenZeppelin 5.x, Foundry |
| Move | Initia Move stdlib v1.2.1 |
| Frontend | Next.js 16, viem, @initia/react-wallet-widget, Tailwind |

## Repository Layout

```
move/              Move module (meridian.move) + tests
contracts/         Solidity stack + Foundry tests
frontend/          Next.js dapp
scripts/level2/    Local-chain bring-up (12 scripts, fully automated)
scripts/level3/    Testnet deploy (initiation-2 + evm-1)
docs/              OPERATIONS.md runbook
SUBMISSION.md      Hackathon submission summary
DEMO_SCRIPT.md     3-min demo narration + shot list
```

## Why Initia Specifically

Initia's Enshrined Liquidity makes LP tokens validator-securing assets. Meridian unlocks the third use: lending collateral. The same capital provides DEX liquidity, secures Initia validators, and now backs loans. No other Cosmos chain has this.

We're also the first dApp to prove the bidirectional EVM-hook + Move-hook IBC pattern with a complete cross-VM application.

## Known Limits

Honest scope before mainnet:

- Prices are admin-set (no Connect Oracle yet)
- L1 `liquidate()` always full-amount (no partial)
- No flash-loan protection on `MANAGER_ROLE`
- Single delegation per user (no multi-validator)
- Positions are address-bound (not transferable NFTs)
- Frontend needs two wallets (Keplr for L1, MetaMask for L2)
- No audit, no formal verification

See `SUBMISSION.md` for the full breakdown.

## License

MIT
