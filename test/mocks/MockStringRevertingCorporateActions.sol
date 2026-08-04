// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockStringRevertingCorporateActions
/// @notice A vault-shaped contract whose every call reverts with a fixed
/// string reason via a catch-all `fallback`. Unlike `MockRevertingCorporateActions`
/// (which reverts a typed custom error) this reverts a plain `Error(string)`,
/// letting a test assert the *exact* underlying reason propagates unswallowed
/// through `LibCorporateActionsPause.inPauseWindow`'s external read calls.
///
/// Used by audit #74: proves a non-zero corporate-actions vault that reverts on
/// the read paths (an EOA, a wrong-ABI contract, or a paused implementation)
/// bubbles the underlying revert rather than being silently caught. This is the
/// deliberate opposite of the mask-0 short-circuit test, which proves the vault
/// is NOT called at all.
contract MockStringRevertingCorporateActions {
    // solhint-disable-next-line payable-fallback, no-complex-fallback
    fallback() external payable {
        revert("vault-reverts");
    }
}
