// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title InterestRateModel - Utilization-based interest rate curve
/// @notice Determines borrow rates based on pool utilization
/// @dev Ported from CrossCredit with no modifications
contract InterestRateModel {
    using Math for uint256;

    /// @notice Base borrow rate (2% APY)
    uint256 public constant BASE_RATE = 0.02e18;

    /// @notice Optimal utilization target (80%)
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18;

    /// @notice Slope below optimal utilization (4%)
    uint256 public constant SLOPE_1 = 0.04e18;

    /// @notice Slope above optimal utilization (75%) - steep to incentivize repayment
    uint256 public constant SLOPE_2 = 0.75e18;

    /// @notice Calculate borrow rate based on utilization
    /// @param totalBorrowed Total amount currently borrowed
    /// @param totalDeposited Total amount deposited by lenders
    /// @return rate Annual borrow rate in 1e18 precision
    function getRate(uint256 totalBorrowed, uint256 totalDeposited) public pure returns (uint256 rate) {
        if (totalDeposited == 0) return 0;

        uint256 utilization = totalBorrowed.mulDiv(1e18, totalDeposited);

        if (utilization <= OPTIMAL_UTILIZATION) {
            // Below optimal: gentle slope
            rate = BASE_RATE + utilization.mulDiv(SLOPE_1, OPTIMAL_UTILIZATION);
        } else {
            // Above optimal: steep slope to incentivize repayment
            rate = BASE_RATE + SLOPE_1
                + (utilization - OPTIMAL_UTILIZATION).mulDiv(SLOPE_2, 1e18 - OPTIMAL_UTILIZATION);
        }
    }

    /// @notice Calculate supply rate (what lenders earn)
    /// @param totalBorrowed Total amount currently borrowed
    /// @param totalDeposited Total amount deposited by lenders
    /// @param protocolFee Protocol's share of interest (in 1e18, e.g., 0.15e18 = 15%)
    /// @return supplyRate Annual supply rate in 1e18 precision
    function getSupplyRate(uint256 totalBorrowed, uint256 totalDeposited, uint256 protocolFee)
        public
        pure
        returns (uint256 supplyRate)
    {
        if (totalDeposited == 0) return 0;

        uint256 borrowRate = getRate(totalBorrowed, totalDeposited);
        uint256 utilization = totalBorrowed.mulDiv(1e18, totalDeposited);

        // Supply rate = borrow rate * utilization * (1 - protocol fee)
        supplyRate = borrowRate.mulDiv(utilization, 1e18).mulDiv(1e18 - protocolFee, 1e18);
    }
}
