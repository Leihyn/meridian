"use client";

import { useEffect, useState, useCallback } from "react";
import { createPublicClient, http } from "viem";
import {
  CONTRACTS,
  L2_RPC,
  LENDING_POOL_ABI,
  COLLATERAL_MANAGER_ABI,
} from "@/lib/contracts";

const client = createPublicClient({
  transport: http(L2_RPC),
});

export interface PoolData {
  totalDeposited: bigint;
  totalBorrowed: bigint;
  utilization: bigint;
  borrowRate: bigint;
  supplyRate: bigint;
  protocolFees: bigint;
}

const ZERO_POOL: PoolData = {
  totalDeposited: 0n,
  totalBorrowed: 0n,
  utilization: 0n,
  borrowRate: 0n,
  supplyRate: 0n,
  protocolFees: 0n,
};

export function usePoolData() {
  const [data, setData] = useState<PoolData>(ZERO_POOL);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const [totalDeposited, totalBorrowed, utilization, borrowRate, supplyRate, protocolFees] =
        await Promise.all([
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "totalAssets",
          }),
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "totalBorrowed",
          }),
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "getUtilization",
          }),
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "getBorrowRate",
          }),
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "getSupplyRate",
          }),
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "protocolFees",
          }),
        ]);

      setData({
        totalDeposited: totalDeposited as bigint,
        totalBorrowed: totalBorrowed as bigint,
        utilization: utilization as bigint,
        borrowRate: borrowRate as bigint,
        supplyRate: supplyRate as bigint,
        protocolFees: protocolFees as bigint,
      });
    } catch (err) {
      console.error("Failed to fetch pool data:", err);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 10_000);
    return () => clearInterval(interval);
  }, [refresh]);

  return { ...data, loading, refresh };
}

export interface UserPosition {
  debt: bigint;
  borrowingPower: bigint;
  healthFactor: bigint;
  isLiquidatable: boolean;
  supplied: bigint;
  maxWithdraw: bigint;
  tokenBalance: bigint;
}

const ZERO_POS: UserPosition = {
  debt: 0n,
  borrowingPower: 0n,
  healthFactor: 0n,
  isLiquidatable: false,
  supplied: 0n,
  maxWithdraw: 0n,
  tokenBalance: 0n,
};

export function useUserPosition(address: string | undefined) {
  const [data, setData] = useState<UserPosition>(ZERO_POS);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    if (!address) {
      setData(ZERO_POS);
      setLoading(false);
      return;
    }

    try {
      const addr = address as `0x${string}`;
      const [debt, borrowingPower, healthFactor, isLiquidatable, supplied, maxWithdraw, tokenBalance] =
        await Promise.all([
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "userDebt",
            args: [addr],
          }),
          client.readContract({
            address: CONTRACTS.COLLATERAL_MANAGER,
            abi: COLLATERAL_MANAGER_ABI,
            functionName: "getBorrowingPower",
            args: [addr],
          }),
          client.readContract({
            address: CONTRACTS.COLLATERAL_MANAGER,
            abi: COLLATERAL_MANAGER_ABI,
            functionName: "getHealthFactor",
            args: [addr],
          }),
          client.readContract({
            address: CONTRACTS.COLLATERAL_MANAGER,
            abi: COLLATERAL_MANAGER_ABI,
            functionName: "isLiquidatable",
            args: [addr],
          }),
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "balanceOf",
            args: [addr],
          }),
          client.readContract({
            address: CONTRACTS.LENDING_POOL,
            abi: LENDING_POOL_ABI,
            functionName: "maxWithdraw",
            args: [addr],
          }),
          client.readContract({
            address: CONTRACTS.MOCK_LENDING_TOKEN,
            abi: LENDING_POOL_ABI,
            functionName: "balanceOf",
            args: [addr],
          }),
        ]);

      setData({
        debt: debt as bigint,
        borrowingPower: borrowingPower as bigint,
        healthFactor: healthFactor as bigint,
        isLiquidatable: isLiquidatable as boolean,
        supplied: supplied as bigint,
        maxWithdraw: maxWithdraw as bigint,
        tokenBalance: tokenBalance as bigint,
      });
    } catch (err) {
      console.error("Failed to fetch user position:", err);
    } finally {
      setLoading(false);
    }
  }, [address]);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 10_000);
    return () => clearInterval(interval);
  }, [refresh]);

  return { ...data, loading, refresh };
}
