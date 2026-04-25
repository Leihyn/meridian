"use client";

import { useState } from "react";
import { L1_CHAIN_ID, L1_RPC, L1_REST } from "@/lib/contracts";

// Keplr doesn't surface a UI for adding custom Cosmos chains. Dapps must
// call `keplr.experimentalSuggestChain()` themselves, which pops a Keplr
// modal that asks the user to approve the addition. This button does that.
export default function AddChainButton() {
  const [status, setStatus] = useState<"idle" | "adding" | "added" | "error">("idle");
  const [err, setErr] = useState<string | null>(null);

  async function add() {
    setStatus("adding");
    setErr(null);
    const keplr = (window as any).keplr;
    if (!keplr) {
      setErr("Keplr not detected - install the Keplr browser extension first");
      setStatus("error");
      return;
    }
    try {
      await keplr.experimentalSuggestChain({
        chainId: L1_CHAIN_ID,
        chainName: "Meridian L1 (local)",
        rpc: L1_RPC,
        rest: L1_REST,
        bip44: { coinType: 60 },
        bech32Config: {
          bech32PrefixAccAddr: "init",
          bech32PrefixAccPub: "initpub",
          bech32PrefixValAddr: "initvaloper",
          bech32PrefixValPub: "initvaloperpub",
          bech32PrefixConsAddr: "initvalcons",
          bech32PrefixConsPub: "initvalconspub",
        },
        currencies: [{ coinDenom: "INIT", coinMinimalDenom: "uinit", coinDecimals: 6 }],
        feeCurrencies: [
          {
            coinDenom: "INIT",
            coinMinimalDenom: "uinit",
            coinDecimals: 6,
            gasPriceStep: { low: 0.15, average: 0.15, high: 0.4 },
          },
        ],
        stakeCurrency: { coinDenom: "INIT", coinMinimalDenom: "uinit", coinDecimals: 6 },
        features: ["eth-address-gen", "eth-key-sign"],
      });
      await keplr.enable(L1_CHAIN_ID);
      setStatus("added");
    } catch (e: any) {
      setErr(e?.message ?? String(e));
      setStatus("error");
    }
  }

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-4">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className="text-white text-sm font-medium">Local Initia chain</p>
          <p className="text-gray-500 text-xs">{L1_CHAIN_ID} - {L1_RPC}</p>
        </div>
        <button
          onClick={add}
          disabled={status === "adding" || status === "added"}
          className="px-4 py-2 bg-teal-600 hover:bg-teal-500 disabled:bg-gray-700 disabled:text-gray-500 text-white text-sm font-medium rounded-lg transition"
        >
          {status === "idle" && "Add to Keplr"}
          {status === "adding" && "Adding..."}
          {status === "added" && "Added"}
          {status === "error" && "Retry"}
        </button>
      </div>
      {err && <p className="mt-2 text-red-400 text-xs break-all">{err}</p>}
    </div>
  );
}
