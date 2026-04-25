import { formatUnits } from "viem";

/** Format a wei-denominated value (18 decimals) to a human-readable string */
export function formatWei(value: bigint, decimals = 18, precision = 2): string {
  return Number(formatUnits(value, decimals)).toLocaleString("en-US", {
    minimumFractionDigits: precision,
    maximumFractionDigits: precision,
  });
}

/** Format a 1e18-precision rate as a percentage */
export function formatRate(value: bigint): string {
  const pct = Number(formatUnits(value, 18)) * 100;
  return pct.toFixed(2) + "%";
}

/** Format a health factor (1e18 = 1.0) */
export function formatHealthFactor(value: bigint): string {
  if (value === 0n) return "N/A";
  const hf = Number(formatUnits(value, 18));
  if (hf > 100) return ">100";
  return hf.toFixed(2);
}

/** Shorten an address: 0x1234...5678 */
export function shortenAddress(addr: string): string {
  return addr.slice(0, 6) + "..." + addr.slice(-4);
}
