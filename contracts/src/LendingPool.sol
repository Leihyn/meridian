// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {CollateralManager} from "./CollateralManager.sol";
import {InterestRateModel} from "./InterestRateModel.sol";

/// @title LendingPool - ERC-4626 vault for lenders + borrowing for collateral depositors
/// @notice Lenders deposit INIT to earn interest. Borrowers with mLP collateral borrow INIT.
contract LendingPool is ERC4626, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant POOL_ADMIN_ROLE = keccak256("POOL_ADMIN_ROLE");

    CollateralManager public immutable collateralManager;
    InterestRateModel public immutable interestRateModel;

    /// @notice Protocol fee on interest (15% = 0.15e18)
    uint256 public constant PROTOCOL_FEE = 0.15e18;

    /// @notice Total amount currently borrowed
    uint256 public totalBorrowed;

    /// @notice User debt balances
    mapping(address => uint256) public userDebt;

    /// @notice User debt timestamp (for interest accrual)
    mapping(address => uint256) public debtTimestamp;

    /// @notice Accumulated protocol fees
    uint256 public protocolFees;

    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event LiquidationBonusPaid(address indexed liquidator, uint256 amount);
    event ProtocolFeesCollected(address indexed collector, uint256 amount);

    constructor(address _asset, address _collateralManager, address _interestRateModel, address admin)
        ERC4626(IERC20(_asset))
        ERC20("Meridian Vault Share", "mVault")
    {
        collateralManager = CollateralManager(_collateralManager);
        interestRateModel = InterestRateModel(_interestRateModel);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_ADMIN_ROLE, admin);
    }

    // ============================================================
    // Borrowing
    // ============================================================

    /// @notice Borrow INIT against mLP collateral
    /// @param amount Amount of INIT to borrow
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");

        // Accrue interest first
        _accrueInterest(msg.sender);

        // Check borrowing power
        uint256 newDebt = userDebt[msg.sender] + amount;
        collateralManager.addDebt(msg.sender, amount);

        // Verify health factor after borrow
        require(collateralManager.getHealthFactor(msg.sender) >= 1e18, "Insufficient collateral");

        // Update state
        userDebt[msg.sender] = newDebt;
        debtTimestamp[msg.sender] = block.timestamp;
        totalBorrowed += amount;

        // Transfer INIT to borrower
        IERC20(asset()).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    /// @notice Repay borrowed INIT
    /// @param amount Amount to repay (use type(uint256).max for full repayment)
    function repay(uint256 amount) external nonReentrant {
        _accrueInterest(msg.sender);

        uint256 debt = userDebt[msg.sender];
        require(debt > 0, "No debt");

        uint256 repayAmount = amount > debt ? debt : amount;

        // Transfer INIT from borrower
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), repayAmount);

        // Update state
        userDebt[msg.sender] -= repayAmount;
        debtTimestamp[msg.sender] = block.timestamp;
        totalBorrowed -= repayAmount;

        // Update collateral manager
        collateralManager.reduceDebt(msg.sender, repayAmount);

        emit Repay(msg.sender, repayAmount);
    }

    // ============================================================
    // Liquidation Support
    // ============================================================

    /// @notice Pay liquidation bonus to liquidator (called by LiquidationEngine)
    /// @param liquidator Address to receive the bonus
    /// @param amount Bonus amount in INIT
    function payLiquidationBonus(address liquidator, uint256 amount) external onlyRole(POOL_ADMIN_ROLE) {
        require(amount <= IERC20(asset()).balanceOf(address(this)), "Insufficient pool balance");
        IERC20(asset()).safeTransfer(liquidator, amount);
        emit LiquidationBonusPaid(liquidator, amount);
    }

    /// @notice Clear debt for a liquidated user (called by LiquidationEngine)
    /// @param user The liquidated user
    /// @param amount Debt amount cleared
    function clearDebt(address user, uint256 amount) external onlyRole(POOL_ADMIN_ROLE) {
        _accrueInterest(user);
        uint256 cleared = amount > userDebt[user] ? userDebt[user] : amount;
        userDebt[user] -= cleared;
        totalBorrowed -= cleared;
        collateralManager.reduceDebt(user, cleared);
    }

    /// @notice Reinstate debt after a failed liquidation IBC round-trip.
    /// @dev The LiquidationEngine cleared the debt optimistically when it
    ///      dispatched the L1 packet. If L1 rejects or the packet times out,
    ///      the debt has to come back or the lender is short the cleared
    ///      principal. `collateralManager.addDebt` is called in the engine;
    ///      we just sync the pool's side.
    function restoreDebt(address user, uint256 amount) external onlyRole(POOL_ADMIN_ROLE) {
        userDebt[user] += amount;
        totalBorrowed += amount;
        debtTimestamp[user] = block.timestamp;
    }

    // ============================================================
    // Interest Accrual
    // ============================================================

    /// @notice Accrue interest for a user's debt
    function _accrueInterest(address user) internal {
        uint256 debt = userDebt[user];
        if (debt == 0 || debtTimestamp[user] == 0) return;

        uint256 elapsed = block.timestamp - debtTimestamp[user];
        if (elapsed == 0) return;

        uint256 rate = interestRateModel.getRate(totalBorrowed, totalAssets());
        // interest = debt * rate * elapsed / (365.25 days)
        uint256 interest = debt.mulDiv(rate, 1e18).mulDiv(elapsed, 365.25 days);

        // Protocol takes its cut
        uint256 protocolCut = interest.mulDiv(PROTOCOL_FEE, 1e18);
        protocolFees += protocolCut;

        // Remaining interest goes to lenders (stays in pool, increases share value)
        userDebt[user] += interest;
        totalBorrowed += interest;

        // Update collateral manager debt
        collateralManager.addDebt(user, interest);

        debtTimestamp[user] = block.timestamp;
    }

    // ============================================================
    // ERC4626 Overrides
    // ============================================================

    /// @notice Total assets available = deposited + interest earned - borrowed out
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalBorrowed - protocolFees;
    }

    // ============================================================
    // View Functions
    // ============================================================

    /// @notice Get current borrow rate
    function getBorrowRate() external view returns (uint256) {
        return interestRateModel.getRate(totalBorrowed, totalAssets());
    }

    /// @notice Get current supply rate (what lenders earn)
    function getSupplyRate() external view returns (uint256) {
        return interestRateModel.getSupplyRate(totalBorrowed, totalAssets(), PROTOCOL_FEE);
    }

    /// @notice Get current utilization
    function getUtilization() external view returns (uint256) {
        uint256 total = totalAssets();
        if (total == 0) return 0;
        return totalBorrowed.mulDiv(1e18, total);
    }

    /// @notice Collect accumulated protocol fees
    function collectProtocolFees(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 fees = protocolFees;
        protocolFees = 0;
        IERC20(asset()).safeTransfer(to, fees);
        emit ProtocolFeesCollected(to, fees);
    }
}
