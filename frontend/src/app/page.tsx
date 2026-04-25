"use client";

import dynamic from "next/dynamic";

// The entire app consumes the Initia wallet widget which touches `window`
// at module load. Skip SSR for the root page content to avoid the
// ReferenceError during pre-render.
const HomeClient = dynamic(() => import("@/components/HomeClient"), { ssr: false });

export default function Home() {
  return <HomeClient />;
}
