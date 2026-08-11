// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright (c) 2024 DIA Foundation
pragma solidity ^0.8.25;

// SYNC NOTE: This interface mirrors DIA Data Association's canonical
// `IDIAOracleV2` (the on-chain feed surface exposed by their oracle
// contracts — the live Base address is `DIA_FEED_BASE` in
// `src/lib/LibDIAFeed.sol`). Last synced 2026-06-29 against the contract's
// verified bytecode (probed via `cast call ... getValue(string)(uint128,uint128) "COIN"`).
//
// Vendored rather than pulled as a dep — the interface is small,
// stable, and DIA does not publish a soldeer package. Same pattern as
// `IAggregatorV2V3` (vendored Chainlink).
//
// We only need the reader surface (`getValue`) — writer methods like
// `setValue` are deliberately omitted; consumers should not depend on
// them.

/// @title IDIAOracleV2
/// @notice Reader interface for DIA Data Association's V2 oracle contracts.
/// Values are returned as 18-decimal `uint128` with a `uint128` push
/// timestamp. Consumers gate staleness by checking `block.timestamp -
/// timestamp` against their own `maxAge` policy.
///
/// Keys are bare symbols (`"COIN"`, `"AMZN"`, `"TSLA"`, ...) not pair
/// strings — `getValue("COIN/USD")` returns zeroes; the published feeds
/// are USD-denominated under the plain symbol.
interface IDIAOracleV2 {
    /// @notice Returns the latest value and push timestamp for the named
    /// feed.
    /// @param key The feed identifier (bare symbol, e.g. `"COIN"`).
    /// @return value The latest price, 18 decimals. Zero when the feed
    /// has never been pushed.
    /// @return timestamp The `block.timestamp` of the latest push. Zero
    /// when the feed has never been pushed.
    function getValue(string memory key) external view returns (uint128 value, uint128 timestamp);
}
