"use client";

import { useUserPosition } from "@/hooks/usePoolData";
import { formatWei, formatHealthFactor } from "@/lib/format";

function healthColor(hf: bigint): string {
  if (hf === 0n) return "text-gray-500";
  const val = Number(hf) / 1e18;
  if (val > 2) return "text-emerald-400";
  if (val > 1.2) return "text-yellow-400";
  return "text-red-400";
}

export default function UserPosition({ address }: { address: string | undefined }) {
  const pos = useUserPosition(address);

  if (!address) {
    return (
      <div className="bg-gray-900 border border-gray-800 rounded-xl p-6 text-center text-gray-500">
        Connect wallet to view your position
      </div>
    );
  }

  if (pos.loading) {
    return (
      <div className="bg-gray-900 border border-gray-800 rounded-xl p-6 animate-pulse h-32" />
    );
  }

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
      <h3 className="text-lg font-semibold text-white mb-4">Your Position</h3>
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <div>
          <p className="text-gray-400 text-sm">Supplied</p>
          <p className="text-white font-medium">{formatWei(pos.supplied)} mINIT</p>
        </div>
        <div>
          <p className="text-gray-400 text-sm">Debt</p>
          <p className="text-white font-medium">{formatWei(pos.debt)} INIT</p>
        </div>
        <div>
          <p className="text-gray-400 text-sm">Borrowing Power</p>
          <p className="text-white font-medium">{formatWei(pos.borrowingPower)} INIT</p>
        </div>
        <div>
          <p className="text-gray-400 text-sm">Health Factor</p>
          <p className={`font-semibold text-lg ${healthColor(pos.healthFactor)}`}>
            {formatHealthFactor(pos.healthFactor)}
          </p>
          {pos.isLiquidatable && (
            <p className="text-red-400 text-xs font-medium">LIQUIDATABLE</p>
          )}
        </div>
      </div>
      <div className="mt-3 pt-3 border-t border-gray-800 flex gap-6">
        <div>
          <p className="text-gray-500 text-xs">Wallet Balance</p>
          <p className="text-gray-300 text-sm">{formatWei(pos.tokenBalance)} INIT</p>
        </div>
        <div>
          <p className="text-gray-500 text-xs">Max Withdraw</p>
          <p className="text-gray-300 text-sm">{formatWei(pos.maxWithdraw)} INIT</p>
        </div>
      </div>
    </div>
  );
}
