// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel model;

    function setUp() public {
        model = new InterestRateModel();
    }

    function test_zeroUtilization() public view {
        uint256 rate = model.getRate(0, 1000e18);
        assertEq(rate, 0.02e18, "Base rate at 0% utilization");
    }

    function test_zeroDeposits() public view {
        uint256 rate = model.getRate(0, 0);
        assertEq(rate, 0, "Zero rate when no deposits");
    }

    function test_optimalUtilization() public view {
        // At 80% utilization
        uint256 rate = model.getRate(800e18, 1000e18);
        // Should be BASE_RATE + SLOPE_1 = 0.02 + 0.04 = 0.06 (6%)
        assertEq(rate, 0.06e18, "Rate at optimal utilization");
    }

    function test_belowOptimal() public view {
        // At 40% utilization (half of optimal)
        uint256 rate = model.getRate(400e18, 1000e18);
        // Should be BASE_RATE + (0.4/0.8) * SLOPE_1 = 0.02 + 0.02 = 0.04 (4%)
        assertEq(rate, 0.04e18, "Rate at 40% utilization");
    }

    function test_aboveOptimal() public view {
        // At 90% utilization
        uint256 rate = model.getRate(900e18, 1000e18);
        // Above optimal: BASE_RATE + SLOPE_1 + ((0.9-0.8)/(1-0.8)) * SLOPE_2
        // = 0.02 + 0.04 + (0.1/0.2) * 0.75 = 0.02 + 0.04 + 0.375 = 0.435
        assertEq(rate, 0.435e18, "Rate at 90% utilization");
    }

    function test_fullUtilization() public view {
        // At 100% utilization
        uint256 rate = model.getRate(1000e18, 1000e18);
        // = 0.02 + 0.04 + 0.75 = 0.81 (81%)
        assertEq(rate, 0.81e18, "Rate at 100% utilization");
    }

    function test_supplyRate() public view {
        // At 80% utilization, 15% protocol fee
        uint256 supplyRate = model.getSupplyRate(800e18, 1000e18, 0.15e18);
        // borrowRate = 0.06, utilization = 0.8
        // supplyRate = 0.06 * 0.8 * (1 - 0.15) = 0.048 * 0.85 = 0.0408
        assertApproxEqAbs(supplyRate, 0.0408e18, 1e14, "Supply rate at optimal utilization");
    }

    function test_supplyRateZeroDeposits() public view {
        uint256 supplyRate = model.getSupplyRate(0, 0, 0.15e18);
        assertEq(supplyRate, 0, "Zero supply rate when no deposits");
    }
}
