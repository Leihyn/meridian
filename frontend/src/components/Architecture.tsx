"use client";

export default function Architecture() {
  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
      <h3 className="text-lg font-semibold text-white mb-4">How It Works</h3>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {/* L1 */}
        <div className="bg-gray-800/50 rounded-lg p-4 border border-gray-700">
          <div className="flex items-center gap-2 mb-3">
            <div className="w-2 h-2 rounded-full bg-teal-400" />
            <p className="text-teal-400 text-sm font-medium">L1 (Move)</p>
          </div>
          <p className="text-gray-300 text-sm mb-2 font-medium">Deposit & Stake</p>
          <ul className="text-gray-500 text-xs space-y-1">
            <li>Deposit LP tokens</li>
            <li>Stake via Enshrined Liquidity</li>
            <li>Mint mLP receipt tokens</li>
            <li>Bridge mLP to L2 via IBC</li>
          </ul>
        </div>

        {/* IBC */}
        <div className="bg-gray-800/50 rounded-lg p-4 border border-gray-700 flex flex-col items-center justify-center">
          <div className="flex items-center gap-2 mb-3">
            <div className="w-2 h-2 rounded-full bg-yellow-400" />
            <p className="text-yellow-400 text-sm font-medium">IBC Bridge</p>
          </div>
          <div className="flex items-center gap-3 text-gray-500">
            <span className="text-xs">L1</span>
            <div className="flex-1 border-t border-dashed border-gray-600 relative min-w-[60px]">
              <div className="absolute -top-3 left-1/2 -translate-x-1/2 text-yellow-400 text-lg">
                &harr;
              </div>
            </div>
            <span className="text-xs">L2</span>
          </div>
          <ul className="text-gray-500 text-xs space-y-1 mt-3">
            <li>mLP collateral credits</li>
            <li>Yield observations</li>
            <li>Liquidation callbacks</li>
          </ul>
        </div>

        {/* L2 */}
        <div className="bg-gray-800/50 rounded-lg p-4 border border-gray-700">
          <div className="flex items-center gap-2 mb-3">
            <div className="w-2 h-2 rounded-full bg-indigo-400" />
            <p className="text-indigo-400 text-sm font-medium">L2 (EVM)</p>
          </div>
          <p className="text-gray-300 text-sm mb-2 font-medium">Lend & Borrow</p>
          <ul className="text-gray-500 text-xs space-y-1">
            <li>Supply INIT to earn yield</li>
            <li>Borrow against mLP collateral</li>
            <li>Yield-boosted borrowing power</li>
            <li>Automated liquidations</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
