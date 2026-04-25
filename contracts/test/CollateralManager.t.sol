// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {YieldOracle} from "../src/YieldOracle.sol";

contract CollateralManagerTest is Test {
    CollateralManager cm;
    YieldOracle oracle;
    address admin = address(this);
    address user1 = address(0x1);
    address mlpToken = address(0xAAA);

    function setUp() public {
        oracle = new YieldOracle(admin);
        cm = new CollateralManager(admin, address(oracle));

        // Grant roles
        cm.grantRole(cm.MANAGER_ROLE(), admin);
        oracle.grantRole(oracle.REPORTER_ROLE(), address(cm));
        oracle.grantRole(oracle.REPORTER_ROLE(), admin);

        // Configure USDC-INIT LP as collateral
        cm.configureCollateral(
            mlpToken,
            0.65e18, // 65% base collateral factor
            1e18, // liquidation threshold
            0.05e18 // 5% liquidation bonus
        );

        // Set price at $1 per mLP token
        cm.setPrice(mlpToken, 1e18);
    }

    function test_creditCollateral() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);
        assertEq(cm.collateralBalances(user1, mlpToken), 10_000e18);
    }

    function test_borrowingPowerNoYield() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);

        // With 65% base factor and $1 price: 10000 * 1 * 0.65 = 6500
        uint256 power = cm.getBorrowingPower(user1);
        assertEq(power, 6_500e18, "Borrowing power without yield");
    }

    function test_borrowingPowerWithYield() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);

        // Set up yield observations in the oracle
        oracle.updatePrincipal(user1, mlpToken, 10_000e18);

        // Record yield observations over time
        oracle.recordYield(user1, mlpToken, 100e18); // First observation
        vm.warp(block.timestamp + 2 hours); // Advance past MIN_OBSERVATION_WINDOW
        oracle.recordYield(user1, mlpToken, 200e18); // Second observation

        // TWAY should now be positive
        uint256 tway = oracle.getTWAY(user1, mlpToken);
        assertTrue(tway > 0, "TWAY should be positive");

        // Borrowing power should be higher than base
        uint256 power = cm.getBorrowingPower(user1);
        assertTrue(power > 6_500e18, "Power should be boosted by yield");
    }

    function test_healthFactorNoDebt() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);
        uint256 hf = cm.getHealthFactor(user1);
        assertEq(hf, type(uint256).max, "Max health factor with no debt");
    }

    function test_healthFactorWithDebt() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);
        cm.addDebt(user1, 3_000e18);

        // HF = borrowing power / debt = 6500 / 3000 = 2.166...
        uint256 hf = cm.getHealthFactor(user1);
        assertApproxEqAbs(hf, 2.166e18, 0.01e18, "Health factor");
    }

    function test_isLiquidatable() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);
        cm.addDebt(user1, 3_000e18);
        assertFalse(cm.isLiquidatable(user1), "Should not be liquidatable");

        // Simulate price crash: LP worth $0.30 now
        cm.setPrice(mlpToken, 0.30e18);
        // New borrowing power: 10000 * 0.30 * 0.65 = 1950
        // HF = 1950 / 3000 = 0.65 < 1.0
        assertTrue(cm.isLiquidatable(user1), "Should be liquidatable after price crash");
    }

    function test_seizeCollateral() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);
        cm.seize(user1, mlpToken, 3_000e18);
        assertEq(cm.collateralBalances(user1, mlpToken), 7_000e18);
    }

    function test_withdrawMaintainsHealthFactor() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);
        cm.addDebt(user1, 3_000e18);

        // Try to withdraw too much — should revert
        vm.expectRevert("Would be undercollateralized");
        cm.withdrawCollateral(user1, mlpToken, 8_000e18);

        // Withdraw a safe amount
        cm.withdrawCollateral(user1, mlpToken, 2_000e18);
        assertEq(cm.collateralBalances(user1, mlpToken), 8_000e18);
    }

    function test_yieldBoostCapped() public {
        cm.creditCollateral(user1, mlpToken, 10_000e18);
        oracle.updatePrincipal(user1, mlpToken, 10_000e18);

        // Simulate extremely high yield (100% annualized)
        oracle.recordYield(user1, mlpToken, 1e18);
        vm.warp(block.timestamp + 2 hours);
        oracle.recordYield(user1, mlpToken, 10_000e18); // Huge reward

        // Even with massive yield, boost should be capped at 15%
        uint256 factor = cm.getAdjustedCollateralFactor(user1, mlpToken);
        // Max factor = 0.65 + 0.15 = 0.80
        assertLe(factor, 0.80e18, "Factor should be capped");
    }

    function test_multipleCollateralTypes() public {
        address ethInitLP = address(0xBBB);

        cm.configureCollateral(ethInitLP, 0.50e18, 1e18, 0.05e18);
        cm.setPrice(ethInitLP, 2e18); // $2 per token

        cm.creditCollateral(user1, mlpToken, 5_000e18); // $5000 at $1
        cm.creditCollateral(user1, ethInitLP, 2_000e18); // $4000 at $2

        // Power = (5000 * 1 * 0.65) + (2000 * 2 * 0.50) = 3250 + 2000 = 5250
        uint256 power = cm.getBorrowingPower(user1);
        assertEq(power, 5_250e18, "Multi-collateral borrowing power");
    }
}
