// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CollateralManager} from "./CollateralManager.sol";
import {YieldOracle} from "./YieldOracle.sol";
import {IIBCAsyncCallback} from "./interfaces/IIBCAsyncCallback.sol";

/// @title IBCReceiver - Receives IBC hook calls from L1 Move module
/// @notice Entry point for cross-chain messages. When mLP or rewards arrive via IBC,
///         the hook middleware calls this contract to credit collateral or record yield.
/// @dev The IBC hook middleware calls functions on this contract with the intermediate
///      sender's context. We validate the call and route to the appropriate handler.
contract IBCReceiver is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant HOOK_CALLER_ROLE = keccak256("HOOK_CALLER_ROLE");

    CollateralManager public immutable collateralManager;
    YieldOracle public immutable yieldOracle;

    /// @notice mLP token address on L2 (the IBC-bridged version)
    address public mlpToken;

    event CollateralCredited(address indexed user, uint256 amount);
    event YieldRecorded(address indexed user, uint256 amount);
    event MLPTokenUpdated(address indexed newToken);

    constructor(address _collateralManager, address _yieldOracle, address admin) {
        collateralManager = CollateralManager(_collateralManager);
        yieldOracle = YieldOracle(_yieldOracle);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(HOOK_CALLER_ROLE, admin); // Admin can call for testing
    }

    /// @notice Set the mLP token address (determined after IBC bridging)
    function setMLPToken(address _mlpToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mlpToken = _mlpToken;
        emit MLPTokenUpdated(_mlpToken);
    }

    /// @notice Credit mLP collateral to a user
    /// @dev Called via IBC hook when mLP tokens arrive from L1 after deposit.
    ///      Must be callable only by the IBC hook intermediate sender (or admin).
    ///      Without this gate, anyone can call it and mint themselves free collateral.
    /// @param user The user who deposited LP on L1
    /// @param amount The amount of mLP tokens credited
    function creditCollateral(address user, uint256 amount) external onlyRole(HOOK_CALLER_ROLE) {
        _creditCollateral(user, amount);
    }

    function _creditCollateral(address user, uint256 amount) internal {
        require(amount > 0, "Zero amount");
        require(mlpToken != address(0), "mLP token not set");

        // Credit collateral in the manager
        collateralManager.creditCollateral(user, mlpToken, amount);

        // Update principal in yield oracle for TWAY calculation
        yieldOracle.updatePrincipal(
            user,
            mlpToken,
            collateralManager.collateralBalances(user, mlpToken)
        );

        emit CollateralCredited(user, amount);
    }

    /// @notice Record yield observation from claimed staking rewards
    /// @dev Called via IBC hook when rewards arrive from L1 after claim_rewards().
    ///      Gated to prevent anyone from inflating TWAY and artificially boosting
    ///      their collateral factor by reporting fake yield.
    /// @param user The user whose rewards were claimed
    /// @param amount The reward amount (in INIT)
    function recordYield(address user, uint256 amount) external onlyRole(HOOK_CALLER_ROLE) {
        require(amount > 0, "Zero amount");

        // Record the yield observation for TWAY computation
        yieldOracle.recordYield(user, mlpToken, amount);

        emit YieldRecorded(user, amount);
    }

    /// @notice Batch credit collateral for multiple users (admin utility)
    function batchCreditCollateral(address[] calldata users, uint256[] calldata amounts)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(users.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < users.length; i++) {
            _creditCollateral(users[i], amounts[i]);
        }
    }
}
