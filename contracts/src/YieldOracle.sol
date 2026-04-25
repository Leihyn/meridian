// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title YieldOracle - Tracks yield from Enshrined Liquidity staking rewards
/// @notice Computes Time-Weighted Average Yield (TWAY) from IBC reward observations
/// @dev Yield data arrives via IBC hook calls from L1 claim_rewards()
contract YieldOracle is AccessControl {
    using Math for uint256;

    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");

    /// @notice Minimum observation window for valid TWAY (1 hour for hackathon, 24h for prod)
    uint256 public constant MIN_OBSERVATION_WINDOW = 1 hours;

    struct YieldObservation {
        uint40 timestamp;
        uint216 cumulativeReward; // cumulative reward amount for this position
    }

    /// @notice user => lpToken => observations
    mapping(address => mapping(address => YieldObservation[])) public observations;

    /// @notice user => lpToken => total principal deposited (in mLP terms)
    mapping(address => mapping(address => uint256)) public principals;

    event YieldRecorded(address indexed user, address indexed lpToken, uint256 amount, uint256 cumulativeReward);
    event PrincipalUpdated(address indexed user, address indexed lpToken, uint256 newPrincipal);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REPORTER_ROLE, admin);
    }

    /// @notice Record a yield observation (called by IBCReceiver when rewards arrive from L1)
    /// @param user The user whose staking rewards were claimed
    /// @param lpToken The mLP token address (identifies the LP position type)
    /// @param amount The reward amount received in this claim
    function recordYield(address user, address lpToken, uint256 amount) external onlyRole(REPORTER_ROLE) {
        YieldObservation[] storage obs = observations[user][lpToken];

        uint216 cumulative = 0;
        if (obs.length > 0) {
            cumulative = obs[obs.length - 1].cumulativeReward;
        }
        cumulative += uint216(amount);

        obs.push(YieldObservation({timestamp: uint40(block.timestamp), cumulativeReward: cumulative}));

        emit YieldRecorded(user, lpToken, amount, cumulative);
    }

    /// @notice Update principal amount for a user's position
    /// @param user The user address
    /// @param lpToken The mLP token address
    /// @param principal The new principal amount
    function updatePrincipal(address user, address lpToken, uint256 principal) external onlyRole(REPORTER_ROLE) {
        principals[user][lpToken] = principal;
        emit PrincipalUpdated(user, lpToken, principal);
    }

    /// @notice Get Time-Weighted Average Yield (annualized) for a user's position
    /// @param user The user address
    /// @param lpToken The mLP token address
    /// @return tway Annualized yield rate in 1e18 precision (e.g., 0.05e18 = 5%)
    function getTWAY(address user, address lpToken) public view returns (uint256 tway) {
        YieldObservation[] storage obs = observations[user][lpToken];
        uint256 principal = principals[user][lpToken];

        if (obs.length < 2 || principal == 0) return 0;

        uint256 first = 0;
        uint256 last = obs.length - 1;

        uint256 elapsed = uint256(obs[last].timestamp) - uint256(obs[first].timestamp);
        if (elapsed < MIN_OBSERVATION_WINDOW) return 0;

        uint256 rewardDelta = uint256(obs[last].cumulativeReward) - uint256(obs[first].cumulativeReward);

        // annualized yield = (rewardDelta / principal) * (365.25 days / elapsed)
        // In 1e18 precision:
        tway = rewardDelta.mulDiv(365.25 days * 1e18, principal * elapsed);
    }

    /// @notice Get the number of observations for a position
    function getObservationCount(address user, address lpToken) external view returns (uint256) {
        return observations[user][lpToken].length;
    }

    /// @notice Get a specific observation
    function getObservation(address user, address lpToken, uint256 index)
        external
        view
        returns (uint40 timestamp, uint216 cumulativeReward)
    {
        YieldObservation storage obs = observations[user][lpToken][index];
        return (obs.timestamp, obs.cumulativeReward);
    }
}
