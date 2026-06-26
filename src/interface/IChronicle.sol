// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright (c) 2024 Chronicle Labs, Inc.
pragma solidity =0.8.25;

// SYNC NOTE: This interface is a hand-typed copy of Chronicle Protocol's
// canonical `IChronicle` from
// `chronicleprotocol/chronicle-std:src/IChronicle.sol`, last synced
// 2026-06-26 against `main` (commit-pinned vendor pending). Re-sync on
// any upstream interface bump. No drift-detection test exists yet.
//
// Vendored rather than pulled as a soldeer/git dep — the interface is
// small, stable, and Chronicle does not currently publish chronicle-std
// to soldeer. Same pattern as `IAggregatorV2V3` (vendored Chainlink).

/// @title IChronicle
/// @notice Interface for Chronicle Protocol's oracle products. Returns
/// 18-decimal `uint256` values. The `*WithAge` variants additionally
/// surface the `block.timestamp` of the last poke, which consumers can
/// use to enforce their own staleness windows.
interface IChronicle {
    /// @notice Returns the oracle's identifier.
    /// @return id The oracle's identifier (named `wat` in Chronicle's upstream
    /// docs — renamed here to avoid Solidity name-shadowing of the function).
    function wat() external view returns (bytes32 id);

    /// @notice Returns the oracle's current value.
    /// @dev Reverts if no value set.
    /// @return value The oracle's current value, 18 decimals.
    function read() external view returns (uint256 value);

    /// @notice Returns the oracle's current value and its age.
    /// @dev Reverts if no value set.
    /// @return value The oracle's current value, 18 decimals.
    /// @return age The `block.timestamp` of the value's last poke.
    function readWithAge() external view returns (uint256 value, uint256 age);

    /// @notice Returns the oracle's current value.
    /// @return isValid True if value exists, false otherwise.
    /// @return value The oracle's current value if it exists, zero otherwise.
    function tryRead() external view returns (bool isValid, uint256 value);

    /// @notice Returns the oracle's current value and its age.
    /// @return isValid True if value exists, false otherwise.
    /// @return value The oracle's current value if it exists, zero otherwise.
    /// @return age The value's age if value exists, zero otherwise.
    function tryReadWithAge() external view returns (bool isValid, uint256 value, uint256 age);
}
