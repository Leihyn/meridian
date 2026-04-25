"use client";

import { useWallet } from "@initia/react-wallet-widget";
import { shortenAddress } from "@/lib/format";

export default function Header() {
  const { address, onboard, view, disconnect } = useWallet();

  return (
    <header className="border-b border-gray-800 bg-gray-950/80 backdrop-blur-sm sticky top-0 z-50">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 h-16 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-indigo-500 to-teal-400 flex items-center justify-center">
            <span className="text-white font-bold text-sm">M</span>
          </div>
          <h1 className="text-xl font-bold text-white tracking-tight">Meridian</h1>
          <span className="text-xs text-gray-500 bg-gray-800 px-2 py-0.5 rounded-full ml-1">
            Testnet
          </span>
        </div>

        <div className="flex items-center gap-3">
          {address ? (
            <>
              <button
                onClick={(e) => view(e as any)}
                className="text-sm text-gray-300 hover:text-white bg-gray-800 hover:bg-gray-700 px-3 py-2 rounded-lg transition font-mono"
              >
                {shortenAddress(address)}
              </button>
              <button
                onClick={() => disconnect()}
                className="text-sm text-gray-500 hover:text-gray-300 transition"
              >
                Disconnect
              </button>
            </>
          ) : (
            <button
              onClick={onboard}
              className="text-sm bg-indigo-600 hover:bg-indigo-500 text-white px-4 py-2 rounded-lg font-medium transition"
            >
              Connect Wallet
            </button>
          )}
        </div>
      </div>
    </header>
  );
}
