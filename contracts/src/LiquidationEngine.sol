// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {CollateralManager} from "./CollateralManager.sol";
import {LendingPool} from "./LendingPool.sol";
import {ICosmos} from "./interfaces/ICosmos.sol";
import {IIBCAsyncCallback} from "./interfaces/IIBCAsyncCallback.sol";

/// @title LiquidationEngine - Handles undercollateralized position liquidation
/// @notice Liquidators call liquidate() on L2. The engine dispatches an IBC message
///         to L1 Move module to unstake and seize the LP tokens.
contract LiquidationEngine is ReentrancyGuard, AccessControl, IIBCAsyncCallback {
    using Math for uint256;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    ICosmos public constant COSMOS = ICosmos(0x00000000000000000000000000000000000000f1);

    CollateralManager public immutable collateralManager;
    LendingPool public immutable lendingPool;

    /// @notice IBC channel to L1
    string public l1Channel;

    /// @notice Move module address on L1 (hex)
    string public l1ModuleAddress;

    /// @notice Callback tracking
    uint64 public nextCallbackId;
    mapping(uint64 => LiquidationCallback) public callbacks;

    struct LiquidationCallback {
        address user;
        address liquidator;
        address collateralToken;
        uint256 debtAmount;
        uint256 collateralAmount;
        bool pending;
    }

    event LiquidationInitiated(
        address indexed user, address indexed liquidator, uint256 debtAmount, uint256 collateralAmount, uint64 callbackId
    );
    event LiquidationCompleted(uint64 indexed callbackId, bool success);

    constructor(address _collateralManager, address _lendingPool, string memory _l1Channel, string memory _l1ModuleAddress, address admin) {
        collateralManager = CollateralManager(_collateralManager);
        lendingPool = LendingPool(payable(_lendingPool));
        l1Channel = _l1Channel;
        l1ModuleAddress = _l1ModuleAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    /// @notice Liquidate an undercollateralized position
    /// @param user The user to liquidate
    /// @param collateralToken The mLP token to seize
    function liquidate(address user, address collateralToken) external nonReentrant {
        // Check user is liquidatable
        uint256 healthFactor = collateralManager.getHealthFactor(user);
        require(healthFactor < 1e18, "Not liquidatable");

        uint256 debt = collateralManager.debts(user);
        uint256 collateralBalance = collateralManager.collateralBalances(user, collateralToken);
        require(collateralBalance > 0, "No collateral of this type");

        // Calculate liquidation amounts
        // Liquidate up to 50% of debt in one call
        uint256 maxLiquidation = debt / 2;
        uint256 collateralPrice = collateralManager.prices(collateralToken);
        require(collateralPrice > 0, "Price not set");

        (, , uint256 liquidationBonus, ) = _getCollateralConfig(collateralToken);

        // collateral to seize = (debt to cover * (1 + bonus)) / collateral price
        uint256 collateralToSeize = maxLiquidation.mulDiv(1e18 + liquidationBonus, collateralPrice);
        if (collateralToSeize > collateralBalance) {
            collateralToSeize = collateralBalance;
        }

        // Seize collateral on L2
        collateralManager.seize(user, collateralToken, collateralToSeize);

        // Clear debt
        lendingPool.clearDebt(user, maxLiquidation);

        // Pay liquidator bonus from pool
        uint256 bonus = maxLiquidation.mulDiv(liquidationBonus, 1e18);
        if (bonus > 0) {
            lendingPool.payLiquidationBonus(msg.sender, bonus);
        }

        // Dispatch IBC message to L1 to unstake the LP tokens
        uint64 callbackId = _dispatchL1Liquidation(user, msg.sender, collateralToSeize);

        callbacks[callbackId] = LiquidationCallback({
            user: user,
            liquidator: msg.sender,
            collateralToken: collateralToken,
            debtAmount: maxLiquidation,
            collateralAmount: collateralToSeize,
            pending: true
        });

        emit LiquidationInitiated(user, msg.sender, maxLiquidation, collateralToSeize, callbackId);
    }

    /// @notice Dispatch IBC message to L1 Move module to unstake LP
    function _dispatchL1Liquidation(address user, address liquidator, uint256 amount)
        internal
        returns (uint64 callbackId)
    {
        callbackId = nextCallbackId++;

        // Build the IBC MsgTransfer with Move hook memo
        // This calls meridian::liquidate(user, liquidator, lp_metadata, validator, amount) on L1
        string memory cosmosUser = COSMOS.to_cosmos_address(user);
        string memory cosmosLiquidator = COSMOS.to_cosmos_address(liquidator);

        // Construct Move hook memo
        // The Move module will decode these args and unstake the LP
        string memory memo = string.concat(
            '{"move":{"message":{"module_address":"',
            l1ModuleAddress,
            '","module_name":"meridian","function_name":"liquidate","type_args":[],"args":["',
            cosmosUser, '","', cosmosLiquidator, '","', _uint256ToString(amount),
            '"]},"async_callback":{"id":', _uint64ToString(callbackId),
            ',"module_address":"', l1ModuleAddress,
            '","module_name":"meridian"}}}'
        );

        // Send a minimal token transfer to trigger the hook
        // The actual value transferred doesn't matter — the hook memo is what triggers the action
        string memory ibcMsg = string.concat(
            '{"@type":"/ibc.applications.transfer.v1.MsgTransfer",',
            '"source_port":"transfer",',
            '"source_channel":"', l1Channel, '",',
            '"token":{"denom":"uinit","amount":"1"},',
            '"sender":"', COSMOS.to_cosmos_address(address(this)), '",',
            '"receiver":"', cosmosUser, '",',
            '"timeout_height":{"revision_number":"0","revision_height":"0"},',
            '"timeout_timestamp":"', _uint256ToString((block.timestamp + 3600) * 1e9), '",',
            '"memo":"', memo, '"}'
        );

        COSMOS.execute_cosmos(ibcMsg);
    }

    // ============================================================
    // IBC Callbacks
    // ============================================================

    /// @notice Called by the IBC hook middleware when the L1 acknowledges our
    ///         MsgTransfer. `success=false` means the Move liquidate() aborted
    ///         on L1 — the packet was accepted by the transfer module but the
    ///         async Move hook rejected it. In that case we must restore the
    ///         seized collateral to the user or it's lost forever.
    function ibc_ack(uint64 callback_id, bool success) external override {
        LiquidationCallback storage cb = callbacks[callback_id];
        require(cb.pending, "No pending callback");
        cb.pending = false;
        if (!success) {
            _restoreSeizedCollateral(cb);
        }
        emit LiquidationCompleted(callback_id, success);
    }

    /// @notice Called when the packet times out before reaching L1. The L2
    ///         side already seized collateral optimistically, so we unwind.
    function ibc_timeout(uint64 callback_id) external override {
        LiquidationCallback storage cb = callbacks[callback_id];
        require(cb.pending, "No pending callback");
        cb.pending = false;
        _restoreSeizedCollateral(cb);
        emit LiquidationCompleted(callback_id, false);
    }

    /// @dev Reverse the L2-side effects of a failed liquidation:
    ///      1. Re-credit the seized collateral to the user
    ///      2. Re-add the cleared debt
    ///      3. Claw back the liquidator bonus (if still available)
    ///      Without this, an IBC outage lets anyone liquidate every position
    ///      then let the packet time out — free collateral from the pool.
    function _restoreSeizedCollateral(LiquidationCallback storage cb) internal {
        collateralManager.creditCollateral(cb.user, cb.collateralToken, cb.collateralAmount);
        collateralManager.addDebt(cb.user, cb.debtAmount);
        // Liquidator bonus was already paid from the pool. We don't claw back
        // from the liquidator's wallet (out of scope), but totalBorrowed needs
        // to go back up to reflect the restored debt.
        lendingPool.restoreDebt(cb.user, cb.debtAmount);
    }

    // ============================================================
    // Admin
    // ============================================================

    function updateL1Config(string memory _l1Channel, string memory _l1ModuleAddress)
        external
        onlyRole(ADMIN_ROLE)
    {
        l1Channel = _l1Channel;
        l1ModuleAddress = _l1ModuleAddress;
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _getCollateralConfig(address token)
        internal
        view
        returns (uint256 baseFactor, uint256 liquidationThreshold, uint256 liquidationBonus, bool enabled)
    {
        (baseFactor, liquidationThreshold, liquidationBonus, enabled) = collateralManager.collateralConfigs(token);
    }

    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }

    function _uint64ToString(uint64 value) internal pure returns (string memory) {
        return _uint256ToString(uint256(value));
    }
}
