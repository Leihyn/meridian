"use client";

import { usePoolData } from "@/hooks/usePoolData";
import { formatRate } from "@/lib/format";

/**
 * Visual representation of the interest rate curve.
 * Shows current utilization position on the curve.
 */
export default function RateCurve() {
  const pool = usePoolData();

  if (pool.loading) {
    return (
      <div className="bg-gray-900 border border-gray-800 rounded-xl p-6 animate-pulse h-48" />
    );
  }

  const utilPct = Number(pool.utilization) / 1e16; // 0-100

  // Generate curve points (utilization-based rate model)
  // Base: 2%, Optimal: 80%, Slope1: 4%, Slope2: 75%
  const points: { x: number; y: number }[] = [];
  for (let u = 0; u <= 100; u += 2) {
    let rate: number;
    if (u <= 80) {
      rate = 2 + (u / 80) * 4;
    } else {
      rate = 2 + 4 + ((u - 80) / 20) * 75;
    }
    points.push({ x: u, y: rate });
  }

  const maxRate = 81; // 2 + 4 + 75
  const svgW = 300;
  const svgH = 120;
  const pad = { top: 10, right: 10, bottom: 20, left: 35 };
  const plotW = svgW - pad.left - pad.right;
  const plotH = svgH - pad.top - pad.bottom;

  function toX(u: number) {
    return pad.left + (u / 100) * plotW;
  }
  function toY(r: number) {
    return pad.top + plotH - (r / maxRate) * plotH;
  }

  const pathD = points
    .map((p, i) => `${i === 0 ? "M" : "L"} ${toX(p.x).toFixed(1)} ${toY(p.y).toFixed(1)}`)
    .join(" ");

  // Current position
  let currentRate: number;
  if (utilPct <= 80) {
    currentRate = 2 + (utilPct / 80) * 4;
  } else {
    currentRate = 2 + 4 + ((utilPct - 80) / 20) * 75;
  }

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-lg font-semibold text-white">Interest Rate Model</h3>
        <div className="flex gap-4 text-sm">
          <span className="text-gray-400">
            Borrow: <span className="text-indigo-400 font-medium">{formatRate(pool.borrowRate)}</span>
          </span>
          <span className="text-gray-400">
            Supply: <span className="text-emerald-400 font-medium">{formatRate(pool.supplyRate)}</span>
          </span>
        </div>
      </div>

      <svg viewBox={`0 0 ${svgW} ${svgH}`} className="w-full h-auto">
        {/* Grid lines */}
        {[0, 20, 40, 60, 80, 100].map((u) => (
          <line
            key={`g-${u}`}
            x1={toX(u)}
            y1={pad.top}
            x2={toX(u)}
            y2={pad.top + plotH}
            stroke="#1f2937"
            strokeWidth={0.5}
          />
        ))}

        {/* Optimal utilization line */}
        <line
          x1={toX(80)}
          y1={pad.top}
          x2={toX(80)}
          y2={pad.top + plotH}
          stroke="#4f46e5"
          strokeWidth={0.5}
          strokeDasharray="3 2"
        />
        <text x={toX(80)} y={pad.top - 2} fill="#6366f1" fontSize={7} textAnchor="middle">
          Optimal 80%
        </text>

        {/* Rate curve */}
        <path d={pathD} fill="none" stroke="#6366f1" strokeWidth={1.5} />

        {/* Area under curve */}
        <path
          d={`${pathD} L ${toX(100).toFixed(1)} ${toY(0).toFixed(1)} L ${toX(0).toFixed(1)} ${toY(0).toFixed(1)} Z`}
          fill="url(#rateGrad)"
          opacity={0.15}
        />

        {/* Current position dot */}
        <circle
          cx={toX(utilPct)}
          cy={toY(currentRate)}
          r={4}
          fill="#818cf8"
          stroke="#030712"
          strokeWidth={1.5}
        />
        <text
          x={toX(utilPct)}
          y={toY(currentRate) - 8}
          fill="#a5b4fc"
          fontSize={7}
          textAnchor="middle"
          fontWeight="bold"
        >
          {currentRate.toFixed(1)}%
        </text>

        {/* X axis labels */}
        {[0, 25, 50, 75, 100].map((u) => (
          <text
            key={`xl-${u}`}
            x={toX(u)}
            y={svgH - 2}
            fill="#6b7280"
            fontSize={7}
            textAnchor="middle"
          >
            {u}%
          </text>
        ))}

        {/* Y axis labels */}
        {[0, 20, 40, 60, 80].map((r) => (
          <text
            key={`yl-${r}`}
            x={pad.left - 4}
            y={toY(r) + 3}
            fill="#6b7280"
            fontSize={7}
            textAnchor="end"
          >
            {r}%
          </text>
        ))}

        <defs>
          <linearGradient id="rateGrad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#6366f1" />
            <stop offset="100%" stopColor="#6366f1" stopOpacity={0} />
          </linearGradient>
        </defs>
      </svg>

      <p className="text-gray-500 text-xs text-center mt-2">
        Utilization: {utilPct.toFixed(1)}% — Base 2% APY, kink at 80%, max ~81% APY
      </p>
    </div>
  );
}
