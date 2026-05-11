// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title LibOracleErrors
/// @notice Shared error definitions used by multiple contracts in the
/// st0x.oracle stack. Hoisting the file-level errors out of each consumer
/// avoids accidental selector drift if one site is updated and another is
/// missed, and gives a single canonical home for cross-cutting governance
/// errors (`OnlyAdmin`, `ZeroAdmin`, `ZeroVault`, `ZeroRegistry`,
/// `OracleNotFound`).
///
/// File-level errors in Solidity are namespaced by their declaring file, so
/// importing them from a shared module yields the same selectors at every
/// consumer.

/// @dev Error raised when the caller is not the admin.
error OnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin.
error ZeroAdmin();

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when a zero address is provided for the registry.
error ZeroRegistry();

/// @dev Error raised when the currently-pointed registry has no entry for
/// `vault`. This includes both the canonical-registry-never-registered case
/// AND the `setRegistry`-pointed-elsewhere case (where the admin swapped
/// the registry to one that doesn't know about this vault).
error OracleNotFound();
