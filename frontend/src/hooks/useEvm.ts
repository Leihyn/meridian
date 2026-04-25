"use client";

import { useState } from "react";
import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  encodeFunctionData,
  parseUnits,
  type Abi,
} from "viem";
import { CONTRACTS, L2_RPC, LENDING_POOL_ABI, ERC20_ABI } from "@/lib/contracts";

const publicClient = createPublicClient({
  transport: http(L2_RPC),
});

/**
 * Send an EVM transaction using the Initia wallet's ethereum provider.
 * Returns the tx hash.
 */
export async function sendEvmTx(
  ethereum: any,
  to: string,
  data: string,
  from: string
): Promise<string> {
  const walletClient = createWalletClient({
    transport: custom(ethereum),
  });

  const hash = await walletClient.sendTransaction({
    account: from as `0x${string}`,
    to: to as `0x${string}`,
    data: data as `0x${string}`,
    gas: 400000n,
    chain: null,
  });

  return hash;
}

export function useEvmAction() {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<string | null>(null);

  async function execute(
    ethereum: any,
    from: string,
    to: string,
    abi: Abi,
    functionName: string,
    args: any[],
    onSuccess?: () => void
  ) {
    setPending(true);
    setError(null);
    setTxHash(null);

    try {
      const data = encodeFunctionData({ abi, functionName, args });
      const hash = await sendEvmTx(ethereum, to, data, from);
      setTxHash(hash);

      // Wait for receipt
      await publicClient.waitForTransactionReceipt({ hash: hash as `0x${string}` });
      onSuccess?.();
    } catch (err: any) {
      setError(err.message || "Transaction failed");
    } finally {
      setPending(false);
    }
  }

  return { execute, pending, error, txHash };
}

/** Check + set ERC20 approval if needed */
export async function ensureApproval(
  ethereum: any,
  from: string,
  token: string,
  spender: string,
  amount: bigint
): Promise<void> {
  const allowance = await publicClient.readContract({
    address: token as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: [from as `0x${string}`, spender as `0x${string}`],
  });

  if ((allowance as bigint) < amount) {
    const data = encodeFunctionData({
      abi: ERC20_ABI,
      functionName: "approve",
      args: [spender as `0x${string}`, amount],
    });
    const hash = await sendEvmTx(ethereum, token, data, from);
    await publicClient.waitForTransactionReceipt({ hash: hash as `0x${string}` });
  }
}
