// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {YieldOracle} from "./YieldOracle.sol";

/// @title CollateralManager - Manages mLP collateral and borrowing power
/// @notice Tracks collateral positions and computes yield-adjusted borrowing power
/// @dev Collateral arrives via IBC from L1 as mLP receipt tokens
contract CollateralManager is AccessControl {
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Maximum yield boost to collateral factor (15% = 1500 bps)
    uint256 public constant MAX_YIELD_BOOST_BPS = 1500;

    struct CollateralConfig {
        uint256 baseFactor; // Base collateral factor in 1e18 (e.g., 0.65e18 = 65%)
        uint256 liquidationThreshold; // Health factor threshold in 1e18 (e.g., 1e18 = 100%)
        uint256 liquidationBonus; // Bonus for liquidators in 1e18 (e.g., 0.05e18 = 5%)
        bool enabled;
    }

    YieldOracle public immutable yieldOracle;

    /// @notice Registered collateral types (mLP token addresses)
    EnumerableSet.AddressSet private _collateralTypes;

    /// @notice Config per collateral type
    mapping(address => CollateralConfig) public collateralConfigs;

    /// @notice User collateral balances: user => mLP token => amount
    mapping(address => mapping(address => uint256)) public collateralBalances;

    /// @notice User debt amounts: user => amount borrowed
    mapping(address => uint256) public debts;

    /// @notice Price per collateral token in USD (1e18 precision)
    /// @dev In production, read from Connect Oracle. For hackathon, admin-set.
    mapping(address => uint256) public prices;

    /// @notice All users who have collateral
    EnumerableSet.AddressSet private _users;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event CollateralSeized(address indexed user, address indexed token, uint256 amount);
    event DebtUpdated(address indexed user, uint256 newDebt);
    event PriceUpdated(address indexed token, uint256 price);
    event CollateralConfigured(address indexed token, uint256 baseFactor, uint256 liquidationThreshold);

    constructor(address admin, address _yieldOracle) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, admin);
        yieldOracle = YieldOracle(_yieldOracle);
    }

    // ============================================================
    // Configuration
    // ============================================================

    /// @notice Register a collateral type (mLP token)
    function configureCollateral(
        address token,
        uint256 baseFactor,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        collateralConfigs[token] =
            CollateralConfig({baseFactor: baseFactor, liquidationThreshold: liquidationThreshold, liquidationBonus: liquidationBonus, enabled: true});
        _collateralTypes.add(token);
        emit CollateralConfigured(token, baseFactor, liquidationThreshold);
    }

    /// @notice Set price for a collateral token (admin oracle for hackathon)
    function setPrice(address token, uint256 price) external onlyRole(MANAGER_ROLE) {
        prices[token] = price;
        emit PriceUpdated(token, price);
    }

    // ============================================================
    // Collateral Operations (called by IBCReceiver / LendingPool)
    // ============================================================

    /// @notice Credit collateral to a user (called when mLP arrives via IBC)
    function creditCollateral(address user, address token, uint256 amount) external onlyRole(MANAGER_ROLE) {
        require(collateralConfigs[token].enabled, "Collateral not enabled");
        collateralBalances[user][token] += amount;
        _users.add(user);
        emit CollateralDeposited(user, token, amount);
    }

    /// @notice Record debt for a user (called by LendingPool on borrow)
    function addDebt(address user, uint256 amount) external onlyRole(MANAGER_ROLE) {
        debts[user] += amount;
        emit DebtUpdated(user, debts[user]);
    }

    /// @notice Reduce debt for a user (called by LendingPool on repay)
    function reduceDebt(address user, uint256 amount) external onlyRole(MANAGER_ROLE) {
        require(debts[user] >= amount, "Debt underflow");
        debts[user] -= amount;
        emit DebtUpdated(user, debts[user]);
    }

    /// @notice Seize collateral during liquidation
    function seize(address user, address token, uint256 amount) external onlyRole(MANAGER_ROLE) {
        require(collateralBalances[user][token] >= amount, "Insufficient collateral");
        collateralBalances[user][token] -= amount;
        emit CollateralSeized(user, token, amount);
    }

    /// @notice Withdraw collateral (user must maintain health factor)
    function withdrawCollateral(address user, address token, uint256 amount) external onlyRole(MANAGER_ROLE) {
        require(collateralBalances[user][token] >= amount, "Insufficient collateral");
        collateralBalances[user][token] -= amount;

        // Check health factor after withdrawal
        if (debts[user] > 0) {
            require(getHealthFactor(user) >= 1e18, "Would be undercollateralized");
        }

        emit CollateralWithdrawn(user, token, amount);
    }

    // ============================================================
    // View Functions
    // ============================================================

    /// @notice Get yield-adjusted collateral factor for a token
    /// @param user The user (yield is per-user)
    /// @param token The mLP token address
    /// @return factor Adjusted collateral factor in 1e18
    function getAdjustedCollateralFactor(address user, address token) public view returns (uint256 factor) {
        CollateralConfig storage config = collateralConfigs[token];
        if (!config.enabled) return 0;

        uint256 baseFactor = config.baseFactor;
        uint256 tway = yieldOracle.getTWAY(user, token);

        // Yield boosts collateral factor, capped at MAX_YIELD_BOOST_BPS
        // boost = min(tway * baseFactor / 10000, maxBoost)
        uint256 yieldBoost = Math.min(tway.mulDiv(baseFactor, 10_000e18), MAX_YIELD_BOOST_BPS * 1e14);

        factor = baseFactor + yieldBoost;
    }

    /// @notice Get total borrowing power for a user across all collateral types
    /// @param user The user address
    /// @return power Total borrowing power in USD (1e18 precision)
    function getBorrowingPower(address user) public view returns (uint256 power) {
        uint256 length = _collateralTypes.length();
        for (uint256 i = 0; i < length; i++) {
            address token = _collateralTypes.at(i);
            uint256 balance = collateralBalances[user][token];
            if (balance == 0) continue;

            uint256 price = prices[token];
            uint256 factor = getAdjustedCollateralFactor(user, token);

            // power += balance * price * factor
            power += balance.mulDiv(price, 1e18).mulDiv(factor, 1e18);
        }
    }

    /// @notice Get health factor for a user
    /// @param user The user address
    /// @return healthFactor In 1e18 precision. < 1e18 means liquidatable.
    function getHealthFactor(address user) public view returns (uint256 healthFactor) {
        uint256 debt = debts[user];
        if (debt == 0) return type(uint256).max;

        uint256 power = getBorrowingPower(user);
        healthFactor = power.mulDiv(1e18, debt);
    }

    /// @notice Check if a user is liquidatable
    function isLiquidatable(address user) external view returns (bool) {
        return getHealthFactor(user) < 1e18;
    }

    /// @notice Get number of registered collateral types
    function collateralTypeCount() external view returns (uint256) {
        return _collateralTypes.length();
    }

    /// @notice Get collateral type at index
    function collateralTypeAt(uint256 index) external view returns (address) {
        return _collateralTypes.at(index);
    }

    /// @notice Get number of users with collateral
    function userCount() external view returns (uint256) {
        return _users.length();
    }
}
