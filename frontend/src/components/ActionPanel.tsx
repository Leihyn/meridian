"use client";

import { useState } from "react";
import { parseUnits } from "viem";
import { useWallet } from "@initia/react-wallet-widget";
import { useEvmAction, ensureApproval } from "@/hooks/useEvm";
import { CONTRACTS, LENDING_POOL_ABI, ERC20_ABI } from "@/lib/contracts";

type Tab = "supply" | "borrow" | "repay" | "withdraw";

const TABS: { id: Tab; label: string }[] = [
  { id: "supply", label: "Supply" },
  { id: "borrow", label: "Borrow" },
  { id: "repay", label: "Repay" },
  { id: "withdraw", label: "Withdraw" },
];

export default function ActionPanel({ onSuccess }: { onSuccess?: () => void }) {
  const { address, ethereum, onboard } = useWallet();
  const [tab, setTab] = useState<Tab>("supply");
  const [amount, setAmount] = useState("");
  const { execute, pending, error, txHash } = useEvmAction();

  if (!address) {
    return (
      <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
        <h3 className="text-lg font-semibold text-white mb-4">Lending Actions</h3>
        <button
          onClick={onboard}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 text-white font-medium rounded-lg transition"
        >
          Connect Wallet
        </button>
      </div>
    );
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!amount || !ethereum || !address) return;

    const wei = parseUnits(amount, 18);

    switch (tab) {
      case "supply":
        await ensureApproval(ethereum, address, CONTRACTS.MOCK_LENDING_TOKEN, CONTRACTS.LENDING_POOL, wei);
        await execute(ethereum, address, CONTRACTS.LENDING_POOL, LENDING_POOL_ABI, "deposit", [wei, address], onSuccess);
        break;

      case "borrow":
        await execute(ethereum, address, CONTRACTS.LENDING_POOL, LENDING_POOL_ABI, "borrow", [wei], onSuccess);
        break;

      case "repay":
        await ensureApproval(ethereum, address, CONTRACTS.MOCK_LENDING_TOKEN, CONTRACTS.LENDING_POOL, wei);
        await execute(ethereum, address, CONTRACTS.LENDING_POOL, LENDING_POOL_ABI, "repay", [wei], onSuccess);
        break;

      case "withdraw":
        await execute(ethereum, address, CONTRACTS.LENDING_POOL, LENDING_POOL_ABI, "withdraw", [wei, address, address], onSuccess);
        break;
    }

    if (!error) setAmount("");
  }

  const actionLabel = {
    supply: "Supply INIT",
    borrow: "Borrow INIT",
    repay: "Repay INIT",
    withdraw: "Withdraw INIT",
  }[tab];

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
      <h3 className="text-lg font-semibold text-white mb-4">Lending Actions</h3>

      {/* Tabs */}
      <div className="flex gap-1 mb-5 bg-gray-800 rounded-lg p-1">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => { setTab(t.id); setAmount(""); }}
            className={`flex-1 py-2 text-sm font-medium rounded-md transition ${
              tab === t.id
                ? "bg-gray-700 text-white"
                : "text-gray-400 hover:text-gray-300"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Form */}
      <form onSubmit={handleSubmit}>
        <div className="mb-4">
          <label className="text-gray-400 text-sm block mb-2">Amount (INIT)</label>
          <input
            type="number"
            step="any"
            min="0"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.00"
            className="w-full bg-gray-800 border border-gray-700 rounded-lg px-4 py-3 text-white placeholder-gray-500 focus:outline-none focus:border-indigo-500 transition"
            disabled={pending}
          />
        </div>

        <button
          type="submit"
          disabled={pending || !amount || Number(amount) <= 0}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 disabled:bg-gray-700 disabled:text-gray-500 text-white font-medium rounded-lg transition"
        >
          {pending ? "Processing..." : actionLabel}
        </button>
      </form>

      {error && (
        <p className="mt-3 text-red-400 text-sm break-all">{error}</p>
      )}

      {txHash && (
        <p className="mt-3 text-emerald-400 text-sm">
          Tx: {txHash.slice(0, 10)}...{txHash.slice(-8)}
        </p>
      )}
    </div>
  );
}
