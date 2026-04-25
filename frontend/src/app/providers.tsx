"use client";

import { useEffect, useState, type ReactNode } from "react";
import type { ComponentType } from "react";
import { L1_CHAIN_ID } from "@/lib/contracts";

// The Initia wallet widget touches `window` at module load, so it can't be
// part of the server-rendered tree. Load it on the client only once mounted.
export default function Providers({ children }: { children: ReactNode }) {
  const [Widget, setWidget] = useState<ComponentType<any> | null>(null);

  useEffect(() => {
    let cancelled = false;
    import("@initia/react-wallet-widget").then((mod) => {
      if (!cancelled) setWidget(() => mod.WalletWidgetProvider);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  if (!Widget) return <>{children}</>;
  return (
    <Widget chainId={L1_CHAIN_ID} theme="dark">
      {children}
    </Widget>
  );
}
