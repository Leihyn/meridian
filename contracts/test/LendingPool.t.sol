// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {YieldOracle} from "../src/YieldOracle.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock INIT", "INIT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LendingPoolTest is Test {
    LendingPool pool;
    CollateralManager cm;
    InterestRateModel irm;
    YieldOracle oracle;
    MockERC20 initToken;

    address admin = address(this);
    address lender = address(0x1111);
    address borrower = address(0x2222);
    address mlpToken = address(0xAAA);

    function setUp() public {
        // Deploy mock INIT token
        initToken = new MockERC20();

        // Deploy oracle and collateral manager
        oracle = new YieldOracle(admin);
        cm = new CollateralManager(admin, address(oracle));
        irm = new InterestRateModel();

        // Deploy lending pool
        pool = new LendingPool(address(initToken), address(cm), address(irm), admin);

        // Grant roles
        cm.grantRole(cm.MANAGER_ROLE(), admin);
        cm.grantRole(cm.MANAGER_ROLE(), address(pool));
        pool.grantRole(pool.POOL_ADMIN_ROLE(), admin);

        // Configure collateral
        cm.configureCollateral(mlpToken, 0.65e18, 1e18, 0.05e18);
        cm.setPrice(mlpToken, 1e18);

        // Mint tokens
        initToken.mint(lender, 100_000e18);
        initToken.mint(borrower, 10_000e18);

        // Lender deposits into pool
        vm.startPrank(lender);
        initToken.approve(address(pool), type(uint256).max);
        pool.deposit(50_000e18, lender);
        vm.stopPrank();

        // Give borrower collateral
        cm.creditCollateral(borrower, mlpToken, 50_000e18);
    }

    function test_lenderDeposit() public view {
        assertEq(pool.totalAssets(), 50_000e18);
        assertTrue(pool.balanceOf(lender) > 0);
    }

    function test_borrow() public {
        vm.startPrank(borrower);
        pool.borrow(20_000e18);
        vm.stopPrank();

        assertEq(initToken.balanceOf(borrower), 30_000e18); // 10k existing + 20k borrowed
        assertEq(pool.totalBorrowed(), 20_000e18);
        assertEq(pool.userDebt(borrower), 20_000e18);
    }

    function test_borrowExceedsCollateral() public {
        vm.startPrank(borrower);
        // Borrowing power = 50000 * 1 * 0.65 = 32500
        // Try to borrow 35000 — should fail
        vm.expectRevert("Insufficient collateral");
        pool.borrow(35_000e18);
        vm.stopPrank();
    }

    function test_repay() public {
        vm.startPrank(borrower);
        pool.borrow(20_000e18);

        // Repay 10000
        initToken.approve(address(pool), type(uint256).max);
        pool.repay(10_000e18);
        vm.stopPrank();

        assertEq(pool.userDebt(borrower), 10_000e18);
        assertEq(pool.totalBorrowed(), 10_000e18);
    }

    function test_repayFull() public {
        vm.startPrank(borrower);
        pool.borrow(20_000e18);

        initToken.approve(address(pool), type(uint256).max);
        pool.repay(type(uint256).max); // Repay all
        vm.stopPrank();

        assertEq(pool.userDebt(borrower), 0);
        assertEq(pool.totalBorrowed(), 0);
    }

    function test_interestAccrual() public {
        vm.startPrank(borrower);
        pool.borrow(20_000e18);
        vm.stopPrank();

        // Advance time by 1 year
        vm.warp(block.timestamp + 365.25 days);

        // Trigger interest accrual by repaying 0+
        vm.startPrank(borrower);
        initToken.approve(address(pool), type(uint256).max);
        pool.repay(1); // Tiny repay to trigger accrual
        vm.stopPrank();

        // Debt should have increased due to interest
        uint256 debt = pool.userDebt(borrower);
        assertTrue(debt > 20_000e18, "Debt should grow with interest");

        // At ~40% utilization (20k borrowed / 50k deposited)
        // Rate ~= 0.02 + (0.4/0.8) * 0.04 = 0.04 (4%)
        // Interest = 20000 * 0.04 = 800 over 1 year
        // Debt should be ~20800
        assertApproxEqAbs(debt, 20_800e18, 50e18, "~4% interest over 1 year");
    }

    function test_utilizationRate() public {
        vm.prank(borrower);
        pool.borrow(20_000e18);

        // totalAssets() = balance(30k) + totalBorrowed(20k) - protocolFees(0) = 50k
        // Utilization = 20000 / 50000 = 40%
        uint256 util = pool.getUtilization();
        assertApproxEqAbs(util, 0.4e18, 0.01e18, "40% utilization");
    }

    function test_borrowAndSupplyRates() public {
        vm.prank(borrower);
        pool.borrow(20_000e18);

        uint256 borrowRate = pool.getBorrowRate();
        uint256 supplyRate = pool.getSupplyRate();

        assertTrue(borrowRate > 0, "Borrow rate positive");
        assertTrue(supplyRate > 0, "Supply rate positive");
        assertTrue(borrowRate > supplyRate, "Borrow rate > supply rate");
    }

    function test_lenderWithdraw() public {
        // Lender withdraws half their position
        vm.startPrank(lender);
        uint256 shares = pool.balanceOf(lender) / 2;
        pool.redeem(shares, lender, lender);
        vm.stopPrank();

        assertTrue(initToken.balanceOf(lender) > 50_000e18, "Got tokens back");
    }

    function test_noDebtRepay() public {
        vm.startPrank(borrower);
        vm.expectRevert("No debt");
        pool.repay(1000e18);
        vm.stopPrank();
    }

    function test_zeroBorrow() public {
        vm.startPrank(borrower);
        vm.expectRevert("Zero amount");
        pool.borrow(0);
        vm.stopPrank();
    }
}
