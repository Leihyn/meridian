# Meridian

Lend against staked LP tokens that keep earning yield.

## The Problem

A liquidity provider on Initia has two bad options. Stake LP tokens via Enshrined Liquidity and earn 8% yield — but lock the capital for the unbonding period. Don't stake, keep liquidity — but earn nothing.

Aave on Ethereum has cTokens and aTokens that stay liquid. Initia has no equivalent. Every dollar staked for yield is a dollar that can't be used for anything else.

## The Solution

Deposit LP on Initia. Get `mLP` — a receipt token that represents the staked position. `mLP` bridges automatically to a Meridian MiniEVM rollup where it's accepted as collateral in a lending pool. Borrow INIT against it. Your underlying LP keeps staking, keeps earning yield, for the entire life of the loan.

One pile of capital, two revenue streams: staking yield on L1 + whatever you do with the borrowed INIT.

## How It Works

```
  Initia L1 (Move VM)                 Meridian L2 (MiniEVM)
  ─────────────────────               ──────────────────────
                                                              
  1. deposit(lp_token)                                        
     → stake with validator                                   
     → mint mLP 1:1                                           
     → IBC transfer mLP                                       
                       ─────── ICS20 + EVM hook ────▶         
                                                              
                                      2. creditCollateral()   
                                         → CollateralManager  
                                         → YieldOracle tracks 
                                                              
                                      3. borrow(amount)       
                                         → LendingPool        
                                         → health factor chk  
                                                              
                                      4. liquidate() if HF<1  
                                         → seize collateral   
                                         → IBC to L1          
                                                              
                       ◀────── ICS20 + Move hook ────         
                                                              
  5. meridian::liquidate()                                    
     → undelegate LP                                          
     → deliver to liquidator                                  
```

Three round-trips. All via IBC with hook middleware on both sides.

## What's Built

**L1 — Move module (`move/sources/meridian.move`)**
- `deposit()` stakes LP, mints mLP, bridges to L2 with an EVM-hook memo
- `claim_rewards()` pulls staking yield, bridges to L2 YieldOracle
- `withdraw()` partially undelegates (uses `extract_delegation` for proportional unstake)
- `liquidate()` fully undelegates, routes to liquidator
- `ibc_ack` / `ibc_timeout` restore bookkeeping on failed packets
- Auth: `hook_caller` field gates withdraw/liquidate to the IBC intermediate sender
- 8 unit tests, 570 lines

**L2 — Solidity stack (`contracts/src/`)**
- `IBCReceiver.sol` — EVM entry point for bridged memos, gated by `HOOK_CALLER_ROLE`
- `CollateralManager.sol` — tracks mLP as collateral with yield-boosted LTV
- `LendingPool.sol` — ERC-4626 vault, utilization-based interest
- `InterestRateModel.sol` — kink at 80% utilization
- `LiquidationEngine.sol` — seizes collateral + dispatches IBC unstake
- `YieldOracle.sol` — TWAY (time-weighted average yield) observations
- 40 Foundry tests, ~900 lines

**Bridge**
- EVM-hook memo format: `{"evm":{"message":{"contract_addr":"0x...","input":"0x<selector+args>"}}}`
- Selectors verified byte-exact cross-chain: `0x2ef35002` (creditCollateral), `0x669e1bb6` (recordYield)
- Access control on both ends, intermediate sender derivation via `SHA256(SHA256(prefix) || channel "/" sender)[:20]`

**Frontend (`frontend/`)**
- Next.js 16 + Turbopack + viem + @initia/react-wallet-widget
- Live pool stats, user position, rate curve chart, architecture diagram
- Keplr integration via `experimentalSuggestChain()` one-click button
- Environment-driven contract addresses so redeploys don't require code changes

**Operations (`scripts/level2/`, `scripts/level3/`, `docs/OPERATIONS.md`)**
- Level 2: full local chain bring-up — 11 scripts, ~1400 lines of bash, end-to-end automated
- Level 3: testnet deploy against `initiation-2` (Initia L1) + `evm-1` (MiniEVM) via existing IBC channel 3077 ↔ 0
- Runbook: the 3 non-obvious IBC hook requirements we found the hard way (receiver = contract addr, ACL default, intermediate sender role)

## Working Surface

| What | Where | Status |
|---|---|---|
| Move module publishes + initializes on live L1 | `scripts/level2/05-deploy-l1.sh` | ✅ tested |
| Solidity stack deploys + wires on live L2 | `scripts/level2/06-deploy-l2.sh` + `07-wire-contracts.sh` | ✅ tested |
| IBC hermes relayer establishes channel | `scripts/level2/04-setup-relayer.sh` | ✅ tested |
| IBC packet L1→L2 with EVM hook → creditCollateral fires | `scripts/level2/08-test-deposit.sh` | ✅ tested (`collateral 0 → 500`) |
| IBC packet L1→L2 for yield → recordYield fires | `scripts/level2/11-test-yield.sh` | ✅ tested (`obs 0 → 1`) |
| L2 liquidation dispatches IBC to L1 | `scripts/level2/10-test-liquidation.sh` | ✅ tested (packet dispatched) |
| Cross-language calldata consistency | `contracts/test/Bridge.t.sol::test_consistency_*CalldataDecodes` | ✅ tested (Move bytes decode in Solidity) |
| Access control on IBC entry points | `contracts/test/Bridge.t.sol::test_accessControl_*` | ✅ tested |
| L1 auth on withdraw/liquidate | `move/tests/meridian_tests.move::test_*_unauthorized` | ✅ tested |

## Tested Scope

- 8 Move tests — memo encoding, auth, state management, IBC callback paths
- 40 Foundry tests — 11 Bridge integration tests + 29 per-contract unit tests
- 1 cross-language consistency test — Move output bytes fed to Solidity low-level call
- 1 end-to-end live IBC round-trip — real packet delivered, `collateralBalances` advanced

All tests pass (`forge test` + `initiad move test`).


## Tech Stack

| Layer | Tech |
|---|---|
| L1 | Initia (Move VM on Cosmos SDK) — `initiad v1.4.4` |
| L2 | Meridian MiniEVM rollup — `minitiad v1.2.15` |
| IBC | Hermes v1.10.5, EVM hook middleware + Move hook middleware |
| Contracts | Solidity 0.8.28, OpenZeppelin 5.x, Foundry |
| Move | Initia Move stdlib v1.2.1 |
| Frontend | Next.js 16 (Turbopack), viem, @initia/react-wallet-widget, Tailwind |

## Try It

```bash
git clone ...
cd meridian
# Local full stack
cd scripts/level2
./00-prereqs.sh          # verify binaries
./01-init-l1.sh          # Initia L1 genesis
./02-init-l2.sh          # MiniEVM L2 genesis
./03-start-chains.sh     # start both
./04-setup-relayer.sh    # hermes config + channel
./05-deploy-l1.sh        # publish Move module
./06-deploy-l2.sh        # deploy Solidity stack
./07-wire-contracts.sh   # grant roles + set hook callers + configure collateral
./08-test-deposit.sh     # live IBC deposit → collateral credited

cd ../../frontend
npm install && npm run dev  # http://localhost:3000
```

## Why This Matters

Initia's Enshrined Liquidity is a structural advantage — LP tokens that secure consensus, earn validator rewards, and (until now) were trapped. Meridian is the DeFi primitive that unlocks them. The same capital that provides liquidity to the DEX and secures Initia validators now also serves as collateral in a lending market. That's three productive uses of one asset. No other Cosmos chain has this.

Bridge-wise, we're not inventing IBC, but we're the first to prove out the full bidirectional EVM+Move hook pattern with a complete dApp. Future Initia rollups that want to build cross-VM products can use this as a reference implementation.
