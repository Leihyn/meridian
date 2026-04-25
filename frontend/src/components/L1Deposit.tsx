"use client";

import { useState } from "react";
import { useWallet } from "@initia/react-wallet-widget";
import { MsgExecute, bcs } from "@initia/initia.js";
import { L1_MODULE_ADDRESS, L1_CHAIN_ID } from "@/lib/contracts";

/**
 * L1 Deposit: Calls the Move module's `deposit` function on Initia L1.
 * This stakes LP tokens with Enshrined Liquidity and bridges mLP to L2.
 */
export default function L1Deposit() {
  const { address, requestInitiaTx, onboard } = useWallet();
  // On local chain, uinit itself is in mstaking.bond_denoms and has a Move
  // Object<Metadata> at a known address. On testnet/mainnet, replace with
  // the real LP pool token metadata. NEXT_PUBLIC_LP_METADATA overrides both.
  const defaultLp =
    process.env.NEXT_PUBLIC_LP_METADATA ??
    "0x8e4733bdabcf7d4afc3d14f0dd46c9bf52fb0fce9e4b996c939e195b8bc891d9"; // uinit metadata on local
  const defaultValidator =
    process.env.NEXT_PUBLIC_DEFAULT_VALIDATOR ??
    "initvaloper1dup9dn3e2cqxhcascqpkw7x86rg82qllzsmzlq";
  const [lpDenom, setLpDenom] = useState(defaultLp);
  const [amount, setAmount] = useState("");
  const [validator, setValidator] = useState(defaultValidator);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<string | null>(null);

  if (!address) {
    return (
      <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
        <h3 className="text-lg font-semibold text-white mb-4">Stake LP Tokens (L1)</h3>
        <p className="text-gray-400 text-sm mb-4">
          Deposit LP tokens on Initia L1 to stake with Enshrined Liquidity.
          mLP receipt tokens are automatically bridged to L2 as collateral.
        </p>
        <button
          onClick={onboard}
          className="w-full py-3 bg-teal-600 hover:bg-teal-500 text-white font-medium rounded-lg transition"
        >
          Connect Wallet
        </button>
      </div>
    );
  }

  async function handleDeposit(e: React.FormEvent) {
    e.preventDefault();
    if (!amount) return;

    setPending(true);
    setError(null);
    setTxHash(null);

    try {
      // meridian::deposit signature:
      //   deposit(user: &signer, lp_metadata: Object<Metadata>, validator: String, amount: u64)
      //
      // MsgExecute auto-injects the signer. Remaining args MUST be BCS-encoded
      // in declaration order. A mismatch silently corrupts state or reverts
      // with an obscure VM error, so encoding them correctly matters.
      const amountU64 = BigInt(Math.floor(Number(amount) * 1e6));
      const msg = new MsgExecute(
        address,
        L1_MODULE_ADDRESS,
        "meridian",
        "deposit",
        [],
        [
          bcs.address().serialize(lpDenom).toBase64(),        // lp_metadata
          bcs.string().serialize(validator).toBase64(),        // validator
          bcs.u64().serialize(amountU64).toBase64(),           // amount
        ]
      );

      const hash = await requestInitiaTx(
        { msgs: [msg], memo: "Meridian: Stake LP" },
        { chainId: L1_CHAIN_ID }
      );

      setTxHash(hash);
      setAmount("");
    } catch (err: any) {
      setError(err.message || "Deposit failed");
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
      <h3 className="text-lg font-semibold text-white mb-2">Stake LP Tokens (L1)</h3>
      <p className="text-gray-500 text-sm mb-4">
        Stake LP tokens via Enshrined Liquidity. mLP receipt tokens bridge to L2 as collateral via IBC.
      </p>

      <form onSubmit={handleDeposit} className="space-y-4">
        <div>
          <label className="text-gray-400 text-sm block mb-2">LP Token</label>
          <input
            type="text"
            value={lpDenom}
            onChange={(e) => setLpDenom(e.target.value)}
            className="w-full bg-gray-800 border border-gray-700 rounded-lg px-4 py-3 text-white text-sm font-mono focus:outline-none focus:border-teal-500 transition"
            placeholder="0x... Move Object<Metadata> address"
          />
        </div>

        <div>
          <label className="text-gray-400 text-sm block mb-2">Amount</label>
          <input
            type="number"
            step="any"
            min="0"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.00"
            className="w-full bg-gray-800 border border-gray-700 rounded-lg px-4 py-3 text-white placeholder-gray-500 focus:outline-none focus:border-teal-500 transition"
            disabled={pending}
          />
        </div>

        <div>
          <label className="text-gray-400 text-sm block mb-2">Validator</label>
          <input
            type="text"
            value={validator}
            onChange={(e) => setValidator(e.target.value)}
            className="w-full bg-gray-800 border border-gray-700 rounded-lg px-4 py-2.5 text-gray-300 text-sm focus:outline-none focus:border-teal-500 transition font-mono"
            disabled={pending}
          />
        </div>

        <button
          type="submit"
          disabled={pending || !amount || Number(amount) <= 0}
          className="w-full py-3 bg-teal-600 hover:bg-teal-500 disabled:bg-gray-700 disabled:text-gray-500 text-white font-medium rounded-lg transition"
        >
          {pending ? "Staking..." : "Stake & Bridge to L2"}
        </button>
      </form>

      {error && <p className="mt-3 text-red-400 text-sm break-all">{error}</p>}
      {txHash && (
        <p className="mt-3 text-emerald-400 text-sm">
          L1 Tx: {txHash.slice(0, 10)}...{txHash.slice(-8)}
        </p>
      )}
    </div>
  );
}
