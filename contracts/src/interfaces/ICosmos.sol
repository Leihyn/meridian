// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICosmos - Initia MiniEVM Cosmos precompile interface
/// @dev Located at address 0x00000000000000000000000000000000000000f1
interface ICosmos {
    /// @notice Execute a Cosmos SDK message (JSON-encoded)
    function execute_cosmos(string memory msg) external returns (bool);

    /// @notice Query Cosmos SDK state (whitelisted paths only)
    function query_cosmos(string memory path, string memory req) external returns (string memory);

    /// @notice Convert EVM address to Cosmos bech32 address
    function to_cosmos_address(address evm_address) external returns (string memory);

    /// @notice Convert Cosmos bech32 address to EVM address
    function to_evm_address(string memory cosmos_address) external returns (address);

    /// @notice Convert ERC20 address to Cosmos bank denom
    function to_denom(address erc20_address) external returns (string memory);

    /// @notice Convert Cosmos bank denom to ERC20 address
    function to_erc20(string memory denom) external returns (address);
}
