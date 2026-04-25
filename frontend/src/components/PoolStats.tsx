"use client";

import { usePoolData } from "@/hooks/usePoolData";
import { formatWei, formatRate } from "@/lib/format";

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
      <p className="text-gray-400 text-sm mb-1">{label}</p>
      <p className="text-2xl font-semibold text-white">{value}</p>
      {sub && <p className="text-gray-500 text-xs mt-1">{sub}</p>}
    </div>
  );
}

export default function PoolStats() {
  const pool = usePoolData();

  if (pool.loading) {
    return (
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        {[...Array(4)].map((_, i) => (
          <div key={i} className="bg-gray-900 border border-gray-800 rounded-xl p-5 animate-pulse h-24" />
        ))}
      </div>
    );
  }

  const tvl = pool.totalDeposited + pool.totalBorrowed;
  const available = pool.totalDeposited;

  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
      <Stat
        label="Total Value Locked"
        value={`${formatWei(tvl)} INIT`}
      />
      <Stat
        label="Available Liquidity"
        value={`${formatWei(available)} INIT`}
        sub={`Borrowed: ${formatWei(pool.totalBorrowed)} INIT`}
      />
      <Stat
        label="Borrow APY"
        value={formatRate(pool.borrowRate)}
        sub={`Supply APY: ${formatRate(pool.supplyRate)}`}
      />
      <Stat
        label="Utilization"
        value={formatRate(pool.utilization)}
        sub={`Protocol fees: ${formatWei(pool.protocolFees)} INIT`}
      />
    </div>
  );
}
