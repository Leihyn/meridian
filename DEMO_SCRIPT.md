# Meridian Demo Script (3 minutes)

## Before Recording

**One-time setup**:
1. Local stack running: `cd scripts/level2 && ./03-start-chains.sh` (L1 + L2 + hermes up)
2. Frontend up: `cd frontend && npm run dev` → http://localhost:3000
3. Keplr configured with local chain (use the in-app "Add to Keplr" button)
4. Keplr imported with admin mnemonic from `_home/state/l1_key_admin.json`
5. MetaMask imported with deployer privkey from `_home/state/l2_deployer_privkey`, local L2 network added (chain id from `cast chain-id --rpc-url http://localhost:8545`)

**Windows to have open**:
- Browser tab: Meridian UI (http://localhost:3000)
- Terminal tab A: live hermes log (`tail -f scripts/level2/_home/logs/hermes.log | grep -i 'relay\|ack'`)
- Terminal tab B: live L2 state (`watch -n 2 'cast call $CM "collateralBalances..."'`)
- VSCode: `move/sources/meridian.move` open, scrolled to `deposit()` entry

**Screen recording software** (OBS / ScreenFlow): 1080p, capture main monitor only.

---

## The Hook (0:00 - 0:15)

> "On Initia, you either stake your LP for 8% yield and lock it — or keep it liquid and earn nothing. Aave solved this for ETH ten years ago. Meridian solves it for staked LP on Initia."

**[Do: open the UI on localhost:3000 — clean first load]**

---

## The Problem Visualized (0:15 - 0:30)

> "A liquidity provider has $50,000 staked. Real yield, real validators. But the moment they want liquidity — to trade, to farm, to rebalance — they unbond, wait 21 days, and lose every dollar of yield during the wait."

**[Do: point at the hero text on the page, specifically "Your yield keeps flowing while you borrow"]**

---

## The Architecture Beat (0:30 - 0:50)

> "Meridian runs on two chains. Initia L1 with Move — where staking lives. A MiniEVM rollup — where lending lives. IBC hooks wire them together. One user transaction, two chains, one bridge."

**[Do: scroll to the Architecture card at the bottom of the page. Pause for 2 seconds.]**

---

## The Money Shot — Deposit (0:50 - 1:30)

This is where the narrative lands. Make it land.

> "Watch. I deposit staked LP on L1 ..."

**[Do: Click "Stake & Bridge to L2". Keplr popup. Confirm.]**

> "...and look at the position card. Zero collateral on L2."

**[Do: Highlight "Supplied: 0.00 mINIT" / "Collateral: 0"]**

**[Cut to terminal tab A showing hermes relay log. Highlight "packet submitted" and "ack: Ok"]**

> "IBC packet. Relayed by Hermes. The EVM hook fires on the MiniEVM side and credits my collateral."

**[Cut back to UI. Position card should now show non-zero collateral.]**

> "No second transaction. No bridge UI. Just one deposit, and I now have a collateral position on the L2 while my LP keeps earning yield on the L1."

---

## Borrow (1:30 - 2:00)

> "Now the productive part. Borrow against it."

**[Do: Switch to MetaMask (or stay if using one wallet). Enter borrow amount. Click Borrow. Confirm.]**

> "Borrowing power grows with yield — the more my staked LP earns, the more I can borrow. The collateral factor itself is time-weighted-average-yield-adjusted."

**[Do: point at Health Factor number. Point at Borrow Rate / Supply Rate.]**

> "Standard utilization-based rates. Nothing exotic on the lending side. What's new is the collateral behind it."

---

## The Liquidation Beat (2:00 - 2:30)

> "What happens if my LP price drops and my position goes underwater?"

**[Do: Admin tool — drop price:
`cast send $CM "setPrice(address,uint256)" $MLP 300000000000000000 ...`]**

> "The LiquidationEngine on L2 detects the unhealthy position, seizes the collateral, and dispatches a Move hook packet back to L1 to undelegate the staked LP. The liquidator gets the LP at a 5% bonus."

**[Do: call liquidate, show packet in hermes log, show updated UI state]**

---

## The Close (2:30 - 3:00)

> "One transaction. Two chains. One wallet. Your LP keeps staking, keeps earning, and also backs a loan. Three productive uses of the same capital."

> "Meridian is live on Initia testnet. 40 Foundry tests and 8 Move tests passing. Full IBC round-trip proven with real packets and real acks."

**[Do: Show the README on GitHub OR the passing test suite in the terminal]**

> "If you stake on Initia, you shouldn't have to choose between yield and liquidity. Thanks for watching."

---

## If Things Go Wrong

**Keplr won't pop up for signing**
The chain isn't added or the mnemonic isn't imported. Re-run the "Add to Keplr" button, approve, then Connect Wallet again.

**Deposit tx succeeds but collateral stays at 0**
Hermes isn't relaying. Check `tail _home/logs/hermes.log`. If it's stuck, `kill $(cat _home/state/hermes.pid)` then `nohup hermes --config ... start &` again.

**Borrow reverts with "Insufficient collateral"**
Health factor math: collateral value × LTV must exceed borrow amount. Drop the borrow amount or wait for collateral to credit.

**UI shows all zeros after deposit**
The address in MetaMask and Keplr don't match (EVM vs cosmos). The L2 contracts credit collateral to the EVM version of your L1 sender — last 20 bytes of the move address. Open MetaMask and confirm the connected address matches.

**Screen recording lag during liquidation demo**
Pre-warm the liquidation engine: call `setPrice` once before recording to JIT-compile the path, revert, then go live.

---

## Shot List (for editing)

| Scene | Duration | Visuals |
|---|---|---|
| Hook | 0:00-0:15 | UI hero section, zoomed |
| Problem | 0:15-0:30 | Close-up on "Your yield keeps flowing" |
| Architecture | 0:30-0:50 | Architecture diagram card, pan |
| Deposit tx | 0:50-1:10 | Keplr popup → tx hash → UI |
| IBC relay | 1:10-1:25 | Split screen UI + hermes log |
| Collateral lands | 1:25-1:30 | Zoom on position card |
| Borrow | 1:30-2:00 | MetaMask + pool stats |
| Liquidation | 2:00-2:30 | Terminal price drop + UI change |
| Close | 2:30-3:00 | GitHub README / tests passing |

---

## Script Adjustments

- Judging a **hackathon**: emphasize "first to do cross-VM IBC hook dApp", show the tests, show the runbook
- Judging for a **grant**: emphasize "unlocks productive staked capital", show the architecture, show users
- Investor pitch: drop the tests, double down on "one dollar, three uses"
- Technical audience: spend time on the hook middleware discovery (ACL, receiver field, intermediate sender)
