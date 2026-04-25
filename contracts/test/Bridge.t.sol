// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {InterestRateModel} from "../src/InterestRateModel.sol";
import {YieldOracle} from "../src/YieldOracle.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {IBCReceiver} from "../src/IBCReceiver.sol";

contract MockINIT is ERC20 {
    constructor() ERC20("Meridian INIT", "mINIT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockMLP is ERC20 {
    constructor() ERC20("Meridian LP Receipt", "mLP") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice ICosmos precompile mock for LiquidationEngine dispatch tests.
/// Real MiniEVM forwards execute_cosmos; in tests we capture the payload.
contract MockCosmos {
    string public lastMsg;
    uint256 public callCount;

    function execute_cosmos(string memory cosmosMsg) external returns (bool) {
        lastMsg = cosmosMsg;
        callCount++;
        return true;
    }

    function to_cosmos_address(address) external pure returns (string memory) {
        return "init1mockcosmosaddr";
    }

    function query_cosmos(string memory, string memory) external pure returns (string memory) {
        return "";
    }

    function to_evm_address(string memory) external pure returns (address) {
        return address(0);
    }

    function to_denom(address) external pure returns (string memory) {
        return "uinit";
    }

    function to_erc20(string memory) external pure returns (address) {
        return address(0);
    }
}

/// @title BridgeTest - End-to-end cross-chain flow simulation
/// @notice Deploys the full Meridian L2 stack and simulates an IBC packet
///         arriving from the Move L1 module. Verifies:
///
///           1. Wiring (all role grants in Deploy.s.sol are correct)
///           2. Happy path: creditCollateral → borrow → accrue → repay → withdrawCollateral
///           3. Liquidation path: under-collateralized → liquidate → IBC dispatch
///           4. Yield path: recordYield boosts collateral factor after MIN_OBSERVATION_WINDOW
///           5. Access control on the IBC entry points
contract BridgeTest is Test {
    InterestRateModel irm;
    YieldOracle oracle;
    CollateralManager cm;
    LendingPool pool;
    LiquidationEngine engine;
    IBCReceiver receiver;
    MockINIT initToken;
    MockMLP mlp;
    MockCosmos cosmos;

    address admin = address(this);
    address lender = address(0xA11CE);
    address borrower = address(0xB0B);
    address liquidator = address(0xC0FFEE);
    address attacker = address(0xBAD);

    // The IBC hook middleware calls the IBCReceiver from a deterministic
    // intermediate sender address. In production that is derived from the
    // channel. For tests we simulate it with a fixed address.
    address ibcHookCaller = address(0x1BC);

    function setUp() public {
        // 1. Deploy cosmos precompile mock at the canonical address
        cosmos = new MockCosmos();
        vm.etch(address(0x00000000000000000000000000000000000000f1), address(cosmos).code);

        // 2. Deploy the full stack (mirrors Deploy.s.sol)
        irm = new InterestRateModel();
        oracle = new YieldOracle(admin);
        cm = new CollateralManager(admin, address(oracle));
        initToken = new MockINIT();
        pool = new LendingPool(address(initToken), address(cm), address(irm), admin);
        engine = new LiquidationEngine(
            address(cm), address(pool), "channel-0", "0x47D11C25C326084F4206DA7A420D6FB7D0FC0992", admin
        );
        receiver = new IBCReceiver(address(cm), address(oracle), admin);

        // 3. Wire roles (mirrors Deploy.s.sol)
        cm.grantRole(cm.MANAGER_ROLE(), address(pool));
        cm.grantRole(cm.MANAGER_ROLE(), address(engine));
        cm.grantRole(cm.MANAGER_ROLE(), address(receiver));
        pool.grantRole(pool.POOL_ADMIN_ROLE(), address(engine));
        oracle.grantRole(oracle.REPORTER_ROLE(), address(receiver));

        // 4. Deploy mLP and register as collateral.
        // In production the mLP ERC20 is created by the MiniEVM when IBC
        // tokens arrive on first transfer; admin then calls setMLPToken.
        mlp = new MockMLP();
        receiver.setMLPToken(address(mlp));
        // base factor 65%, liq threshold 100%, liq bonus 5%
        cm.configureCollateral(address(mlp), 0.65e18, 1e18, 0.05e18);
        cm.setPrice(address(mlp), 1e18);

        // 5. Authorize the IBC hook caller on the receiver
        receiver.grantRole(receiver.HOOK_CALLER_ROLE(), ibcHookCaller);

        // 6. Fund lender + bootstrap pool liquidity
        initToken.mint(lender, 100_000e18);
        vm.startPrank(lender);
        initToken.approve(address(pool), type(uint256).max);
        pool.deposit(50_000e18, lender);
        vm.stopPrank();
    }

    // ============================================================
    // Simulation helper — mirrors what the IBC hook middleware does
    // ============================================================

    /// @dev Mimics the IBC EVM hook firing with an ABI-encoded calldata payload
    ///      matching what build_credit_collateral_memo SHOULD produce on L1.
    function _simulateIBCDeposit(address user, uint256 amount) internal {
        // On real chain the mLP ERC20 would be transferred to CollateralManager
        // as part of the IBC packet. We mint directly to reflect that state.
        mlp.mint(address(cm), amount);
        vm.prank(ibcHookCaller);
        receiver.creditCollateral(user, amount);
    }

    function _simulateIBCYield(address user, uint256 amount) internal {
        vm.prank(ibcHookCaller);
        receiver.recordYield(user, amount);
    }

    // ============================================================
    // 1. HAPPY PATH: full deposit → borrow → repay → withdraw
    // ============================================================

    function test_happyPath_depositBorrowRepayWithdraw() public {
        // (1) IBC packet arrives — borrower now has 50k mLP as collateral
        _simulateIBCDeposit(borrower, 50_000e18);
        assertEq(cm.collateralBalances(borrower, address(mlp)), 50_000e18, "collateral credited");
        assertEq(oracle.principals(borrower, address(mlp)), 50_000e18, "principal tracked");

        // (2) Borrower takes 20k INIT
        // Borrowing power = 50000 * 1 * 0.65 = 32500, so 20k is safe
        vm.prank(borrower);
        pool.borrow(20_000e18);
        assertEq(initToken.balanceOf(borrower), 20_000e18, "got borrowed INIT");
        assertEq(pool.userDebt(borrower), 20_000e18);

        // (3) Fast-forward ~6 months and repay in full
        vm.warp(block.timestamp + 182 days);
        vm.startPrank(borrower);
        initToken.approve(address(pool), type(uint256).max);
        // Mint a little extra to cover interest
        vm.stopPrank();
        initToken.mint(borrower, 1000e18);
        vm.startPrank(borrower);
        pool.repay(type(uint256).max);
        vm.stopPrank();
        assertEq(pool.userDebt(borrower), 0, "fully repaid");

        // (4) Withdraw collateral back (simulates L2 dispatching IBC withdraw)
        vm.prank(admin);
        cm.withdrawCollateral(borrower, address(mlp), 50_000e18);
        assertEq(cm.collateralBalances(borrower, address(mlp)), 0, "collateral withdrawn");
    }

    // ============================================================
    // 2. LIQUIDATION PATH: price crash → liquidate → IBC dispatch
    // ============================================================

    function test_liquidationPath_priceCrashSeizesAndDispatchesIBC() public {
        _simulateIBCDeposit(borrower, 50_000e18);

        // Max out borrow
        vm.prank(borrower);
        pool.borrow(30_000e18);

        // Price crashes 50% → collateral worth 25k, debt 30k → health < 1
        cm.setPrice(address(mlp), 0.5e18);
        assertTrue(cm.isLiquidatable(borrower), "should be liquidatable");

        // Liquidator pounces
        uint256 callsBefore = MockCosmos(address(0x00000000000000000000000000000000000000f1)).callCount();
        vm.prank(liquidator);
        engine.liquidate(borrower, address(mlp));

        // Assertions:
        // - Collateral seized on L2
        // - Debt halved (maxLiquidation = debt/2 = 15k)
        // - IBC message dispatched to L1
        assertTrue(cm.collateralBalances(borrower, address(mlp)) < 50_000e18, "collateral seized");
        assertEq(pool.userDebt(borrower), 15_000e18, "half of debt cleared");
        uint256 callsAfter = MockCosmos(address(0x00000000000000000000000000000000000000f1)).callCount();
        assertEq(callsAfter, callsBefore + 1, "one IBC dispatch fired");
    }

    /// @notice Critical safety property: if the L1 unstake packet fails or
    ///         times out, the L2 collateral that was optimistically seized
    ///         MUST be restored to the user. Otherwise an IBC outage lets
    ///         liquidators drain every position then let packets time out.
    function test_liquidation_timeoutRestoresCollateral() public {
        _simulateIBCDeposit(borrower, 50_000e18);
        vm.prank(borrower);
        pool.borrow(30_000e18);

        // Drop price to liquidatable
        cm.setPrice(address(mlp), 0.5e18);
        assertTrue(cm.isLiquidatable(borrower));

        uint256 collBefore = cm.collateralBalances(borrower, address(mlp));
        uint256 debtBefore = pool.userDebt(borrower);
        uint256 tbBefore = pool.totalBorrowed();

        // Trigger liquidation
        vm.prank(liquidator);
        engine.liquidate(borrower, address(mlp));

        // Collateral seized, debt halved
        uint256 collAfterSeize = cm.collateralBalances(borrower, address(mlp));
        assertLt(collAfterSeize, collBefore, "collateral reduced");
        assertLt(pool.userDebt(borrower), debtBefore, "debt cleared");

        // Give the engine the MANAGER_ROLE so it can reinstate collateral.
        // In production, wiring script 07 grants this as part of setup.
        cm.grantRole(cm.MANAGER_ROLE(), address(engine));
        // LiquidationEngine needs MANAGER_ROLE on CM to restore. Already has it.

        // Simulate IBC timeout — the hook middleware calls back with the
        // callback_id the engine assigned on dispatch.
        uint64 cbId = engine.nextCallbackId() - 1;
        engine.ibc_timeout(cbId);

        // All state unwound
        assertEq(cm.collateralBalances(borrower, address(mlp)), collBefore, "coll restored");
        assertEq(pool.userDebt(borrower), debtBefore, "debt restored");
        assertEq(pool.totalBorrowed(), tbBefore, "totalBorrowed restored");
        assertFalse(cm.isLiquidatable(borrower) == false && cm.prices(address(mlp)) == 0.5e18,
            "position liquidatable again (price still low)");
    }

    function test_liquidation_nonLiquidatableReverts() public {
        _simulateIBCDeposit(borrower, 50_000e18);
        vm.prank(borrower);
        pool.borrow(10_000e18); // well below limit

        vm.prank(liquidator);
        vm.expectRevert("Not liquidatable");
        engine.liquidate(borrower, address(mlp));
    }

    // ============================================================
    // 3. YIELD PATH: recordYield boosts collateral factor
    // ============================================================

    function test_yieldPath_boostsCollateralFactor() public {
        _simulateIBCDeposit(borrower, 50_000e18);

        // Record a yield observation at t=0
        uint256 t0 = block.timestamp;
        _simulateIBCYield(borrower, 500e18);

        // Advance MIN_OBSERVATION_WINDOW + 1 and record another observation
        vm.warp(t0 + 1 hours + 1);
        _simulateIBCYield(borrower, 500e18);

        // TWAY annualized: 500/50000 = 1% over 1 hour → ~87.6% annualized (extreme for test)
        // Effective factor should be baseFactor + capped boost
        uint256 factor = cm.getAdjustedCollateralFactor(borrower, address(mlp));
        assertTrue(factor > 0.65e18, "factor boosted above base");

        // Cap: MAX_YIELD_BOOST_BPS = 1500 → max boost = 0.15
        assertLe(factor, 0.65e18 + 0.15e18, "factor respects max boost cap");
    }

    // ============================================================
    // 4. WIRING / ROLE GRANT INTEGRITY
    // ============================================================

    function test_wiring_allRolesGranted() public view {
        assertTrue(cm.hasRole(cm.MANAGER_ROLE(), address(pool)), "pool to cm");
        assertTrue(cm.hasRole(cm.MANAGER_ROLE(), address(engine)), "engine to cm");
        assertTrue(cm.hasRole(cm.MANAGER_ROLE(), address(receiver)), "receiver to cm");
        assertTrue(pool.hasRole(pool.POOL_ADMIN_ROLE(), address(engine)), "engine to pool");
        assertTrue(oracle.hasRole(oracle.REPORTER_ROLE(), address(receiver)), "receiver to oracle");
    }

    // ============================================================
    // 5. ACCESS CONTROL ON IBC ENTRY POINTS  <<< BUG EXPECTED HERE
    // ============================================================

    /// @notice An unauthorized caller must NOT be able to mint free collateral
    ///         by calling the IBC entry point directly. This test currently
    ///         FAILS against the original code — creditCollateral has no
    ///         onlyRole check. Fixing IBCReceiver.creditCollateral turns
    ///         this green.
    function test_accessControl_creditCollateralRequiresHookRole() public {
        bytes32 role = receiver.HOOK_CALLER_ROLE(); // cache before prank so it is not consumed
        mlp.mint(address(cm), 1_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role
            )
        );
        vm.prank(attacker);
        receiver.creditCollateral(attacker, 1_000_000e18);
    }

    /// @notice Same protection must apply to recordYield — otherwise anyone
    ///         can inflate TWAY and artificially boost their collateral factor.
    function test_accessControl_recordYieldRequiresHookRole() public {
        bytes32 role = receiver.HOOK_CALLER_ROLE();
        _simulateIBCDeposit(borrower, 50_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role
            )
        );
        vm.prank(attacker);
        receiver.recordYield(borrower, 1_000_000e18);
    }

    /// @notice Legitimate hook caller path still works after fix.
    function test_accessControl_hookCallerCanCredit() public {
        mlp.mint(address(cm), 100e18);
        vm.prank(ibcHookCaller);
        receiver.creditCollateral(borrower, 100e18);
        assertEq(cm.collateralBalances(borrower, address(mlp)), 100e18);
    }

    // ============================================================
    // 6. MULTI-USER INTERLEAVING
    // ============================================================

    // ============================================================
    // 7. CROSS-LANGUAGE CONSISTENCY
    //
    // These tests verify the L1 Move memo builder and the L2 Solidity
    // decoder agree byte-for-byte. We take the EXACT calldata bytes
    // produced by `meridian::build_credit_collateral_memo` for a known
    // (user, amount) and feed them to IBCReceiver via a low-level call.
    // If this passes, the bridge is internally consistent — whatever
    // IBC infra delivers in between, both ends speak the same language.
    //
    // Reference inputs (matches meridian_tests.move::test_credit_collateral_memo_has_abi_calldata):
    //   user   = @0xBEEF (32-byte Move addr → 0x...beef as ABI address)
    //   amount = 1000   (0x3e8)
    // ============================================================

    function test_consistency_creditCollateralCalldataDecodes() public {
        // Bytes produced by the Move memo builder, sliced from "0x" onward:
        //   selector (2ef35002) + address padded (32 bytes) + uint256 (32 bytes)
        bytes memory calldata_ = hex"2ef35002"
            hex"000000000000000000000000000000000000000000000000000000000000beef"
            hex"00000000000000000000000000000000000000000000000000000000000003e8";

        // The mLP arrives on L2 and is held by CollateralManager before
        // the hook fires. Mirror that state.
        mlp.mint(address(cm), 1000);

        // The IBC hook middleware invokes this call from the intermediate
        // sender on the EVM side.
        vm.prank(ibcHookCaller);
        (bool ok, bytes memory ret) = address(receiver).call(calldata_);
        assertTrue(ok, string(ret));

        // Expected outcome: @0xBEEF on L1 maps to 0x...beef on L2, and
        // 1000 units of collateral were credited.
        assertEq(cm.collateralBalances(address(0xBEEF), address(mlp)), 1000, "credited");
    }

    function test_consistency_recordYieldCalldataDecodes() public {
        // Pre-seed user with collateral so recordYield has a principal to track
        mlp.mint(address(cm), 1000);
        vm.prank(ibcHookCaller);
        receiver.creditCollateral(address(0xBEEF), 1000);

        // Bytes produced by the Move memo builder for recordYield:
        //   selector (669e1bb6) + address (0x...beef) + uint256 (0x1f4 = 500)
        bytes memory calldata_ = hex"669e1bb6"
            hex"000000000000000000000000000000000000000000000000000000000000beef"
            hex"00000000000000000000000000000000000000000000000000000000000001f4";

        vm.prank(ibcHookCaller);
        (bool ok, bytes memory ret) = address(receiver).call(calldata_);
        assertTrue(ok, string(ret));

        assertEq(oracle.getObservationCount(address(0xBEEF), address(mlp)), 1, "observation recorded");
    }

    function test_multipleUsers_independentPositions() public {
        address alice = address(0xA1);
        address bob = address(0xB2);

        _simulateIBCDeposit(alice, 10_000e18);
        _simulateIBCDeposit(bob, 20_000e18);

        vm.prank(alice); pool.borrow(5_000e18);
        vm.prank(bob); pool.borrow(10_000e18);

        assertEq(pool.userDebt(alice), 5_000e18);
        assertEq(pool.userDebt(bob), 10_000e18);
        assertEq(cm.collateralBalances(alice, address(mlp)), 10_000e18);
        assertEq(cm.collateralBalances(bob, address(mlp)), 20_000e18);
        assertEq(pool.totalBorrowed(), 15_000e18);
    }
}
