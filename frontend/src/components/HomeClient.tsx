"use client";

import { useWallet } from "@initia/react-wallet-widget";
import Header from "@/components/Header";
import PoolStats from "@/components/PoolStats";
import UserPosition from "@/components/UserPosition";
import ActionPanel from "@/components/ActionPanel";
import L1Deposit from "@/components/L1Deposit";
import Architecture from "@/components/Architecture";
import RateCurve from "@/components/RateCurve";
import AddChainButton from "@/components/AddChainButton";
import { usePoolData, useUserPosition } from "@/hooks/usePoolData";

export default function HomeClient() {
  const { address } = useWallet();
  const pool = usePoolData();
  const position = useUserPosition(address);

  function refreshAll() {
    pool.refresh();
    position.refresh();
  }

  return (
    <>
      <Header />
      <main className="flex-1 max-w-7xl mx-auto w-full px-4 sm:px-6 py-8 space-y-6">
        <section className="mb-2">
          <h2 className="text-3xl font-bold text-white mb-2">
            Lend Against Staked LP
          </h2>
          <p className="text-gray-400 max-w-2xl">
            Deposit LP tokens on Initia L1 to stake with Enshrined Liquidity.
            Your yield keeps flowing while you borrow against your position on L2.
          </p>
        </section>

        <AddChainButton />
        <PoolStats />
        <UserPosition address={address} />

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <ActionPanel onSuccess={refreshAll} />
          <L1Deposit />
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <RateCurve />
          <Architecture />
        </div>

        <footer className="text-center text-gray-600 text-sm py-8 border-t border-gray-800">
          Meridian v2 — Built on Initia (Move + EVM + IBC)
        </footer>
      </main>
    </>
  );
}
