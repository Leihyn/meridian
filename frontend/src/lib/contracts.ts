import { type Abi } from "viem";

// Deployed contract addresses on L2.
//
// In dev, NEXT_PUBLIC_CONTRACTS_JSON can point to scripts/level2/_home/state/l2_deployed.json
// so the frontend picks up addresses without a manual edit after each redeploy.
// In prod, populate NEXT_PUBLIC_CONTRACT_* vars at build time.
function deployedFromEnv() {
  const raw = process.env.NEXT_PUBLIC_DEPLOYED_JSON;
  if (!raw) return null;
  try {
    const arr = JSON.parse(raw) as Array<{ name: string; addr: string }>;
    const byName = Object.fromEntries(arr.map((c) => [c.name, c.addr as `0x${string}`]));
    return {
      INTEREST_RATE_MODEL: byName.InterestRateModel,
      YIELD_ORACLE: byName.YieldOracle,
      COLLATERAL_MANAGER: byName.CollateralManager,
      MOCK_LENDING_TOKEN: byName.MockLendingToken,
      LENDING_POOL: byName.LendingPool,
      LIQUIDATION_ENGINE: byName.LiquidationEngine,
      IBC_RECEIVER: byName.IBCReceiver,
    } as const;
  } catch {
    return null;
  }
}

const FALLBACK = {
  INTEREST_RATE_MODEL: "0x9028b475695e12fe587f46d1d146a1db8c704421",
  YIELD_ORACLE: "0x627b1fac0e776714c07dbe1674319be97c1a98dd",
  COLLATERAL_MANAGER: "0x8ddf5a4d10854f011f2e29c1dc09d6cf1b270b9a",
  MOCK_LENDING_TOKEN: "0xcd500ba0997b8d6b6ea1995abb9b07867781c575",
  LENDING_POOL: "0xce99bec90009c7a6ee99448869e3522e6deac105",
  LIQUIDATION_ENGINE: "0x4739846e84ef2638404704becb1d64df52b01ae0",
  IBC_RECEIVER: "0x5de0cedbff88a6492cb386cba9afb08cf51e36a1",
} as const;

export const CONTRACTS = (deployedFromEnv() ?? FALLBACK) as typeof FALLBACK;

export const L1_MODULE_ADDRESS =
  process.env.NEXT_PUBLIC_L1_MODULE_ADDRESS ??
  "0x000000000000000000000000b0aa765f0cafe3e482258c630b57cee436b839a5";

export const L2_RPC = process.env.NEXT_PUBLIC_L2_RPC ?? "http://localhost:8545";
export const L2_CHAIN_ID = process.env.NEXT_PUBLIC_L2_CHAIN_ID ?? "meridian-l2-local";
export const L1_CHAIN_ID = process.env.NEXT_PUBLIC_L1_CHAIN_ID ?? "meridian-l1-local";
export const L1_REST = process.env.NEXT_PUBLIC_L1_REST ?? "http://localhost:1317";
export const L1_RPC = process.env.NEXT_PUBLIC_L1_RPC ?? "http://localhost:26657";
export const IBC_CHANNEL = process.env.NEXT_PUBLIC_IBC_CHANNEL ?? "channel-0";

// Simplified ABIs — only the functions the frontend calls
export const LENDING_POOL_ABI = [
  {
    type: "function",
    name: "borrow",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "repay",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "deposit",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "withdraw",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "owner", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "getBorrowRate",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getSupplyRate",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getUtilization",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "totalAssets",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "totalBorrowed",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "userDebt",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "totalSupply",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "asset",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "maxWithdraw",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "protocolFees",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const satisfies Abi;

export const COLLATERAL_MANAGER_ABI = [
  {
    type: "function",
    name: "getBorrowingPower",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "power", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getHealthFactor",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "healthFactor", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isLiquidatable",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "collateralBalances",
    inputs: [
      { name: "", type: "address" },
      { name: "", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "debts",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "prices",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getAdjustedCollateralFactor",
    inputs: [
      { name: "user", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [{ name: "factor", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "collateralConfigs",
    inputs: [{ name: "", type: "address" }],
    outputs: [
      { name: "baseFactor", type: "uint256" },
      { name: "liquidationThreshold", type: "uint256" },
      { name: "liquidationBonus", type: "uint256" },
      { name: "enabled", type: "bool" },
    ],
    stateMutability: "view",
  },
] as const satisfies Abi;

export const YIELD_ORACLE_ABI = [
  {
    type: "function",
    name: "getTWAY",
    inputs: [
      { name: "user", type: "address" },
      { name: "lpToken", type: "address" },
    ],
    outputs: [{ name: "tway", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getObservationCount",
    inputs: [
      { name: "user", type: "address" },
      { name: "lpToken", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "principals",
    inputs: [
      { name: "", type: "address" },
      { name: "", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const satisfies Abi;

export const LIQUIDATION_ENGINE_ABI = [
  {
    type: "function",
    name: "liquidate",
    inputs: [
      { name: "user", type: "address" },
      { name: "collateralToken", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "callbacks",
    inputs: [{ name: "", type: "uint64" }],
    outputs: [
      { name: "user", type: "address" },
      { name: "liquidator", type: "address" },
      { name: "collateralToken", type: "address" },
      { name: "debtAmount", type: "uint256" },
      { name: "collateralAmount", type: "uint256" },
      { name: "pending", type: "bool" },
    ],
    stateMutability: "view",
  },
] as const satisfies Abi;

export const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "allowance",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "symbol",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
  },
] as const satisfies Abi;
