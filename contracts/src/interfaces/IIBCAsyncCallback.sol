// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IIBCAsyncCallback - Callback interface for IBC async operations
/// @dev Implement this to receive ack/timeout notifications for outgoing IBC messages
interface IIBCAsyncCallback {
    /// @notice Called when an IBC packet is acknowledged
    /// @param callback_id The ID assigned to this callback
    /// @param success Whether the packet was successfully processed on the destination
    function ibc_ack(uint64 callback_id, bool success) external;

    /// @notice Called when an IBC packet times out
    /// @param callback_id The ID assigned to this callback
    function ibc_timeout(uint64 callback_id) external;
}
